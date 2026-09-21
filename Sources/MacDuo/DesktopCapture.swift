import AppKit
import ScreenCaptureKit
import CoreMedia
import OSLog

final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let frames = FrameStore()
    private let logger = Logger(subsystem:"local.lidflow.mac",category:"capture")
    private var stream: SCStream?
    private let queue = DispatchQueue(label:"local.lidflow.frames",qos:.userInteractive)
    private var generation = 0
    private var starting = false
    private var cachedDisplays: [CGDirectDisplayID:SCDisplay] = [:]
    // This identity belongs to our process, not a window or Space. Keep it when
    // settings are closed or moved offscreen so every new stream excludes us.
    private var ownApplication: SCRunningApplication?
    var onFailure: ((String) -> Void)?
    var onUnavailable: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    var isRunning: Bool { stream != nil || starting }

    @MainActor private func refreshAvailableContent() async throws -> SCShareableContent {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
        if let own = content.applications.first(where: { $0.processID == getpid() }) { ownApplication = own }
        cachedDisplays = Dictionary(content.displays.map { ($0.displayID,$0) },uniquingKeysWith:{ first,_ in first })
        let elapsed = Int((ProcessInfo.processInfo.systemUptime-startedAt)*1_000)
        logger.notice("Shareable display content refreshed in \(elapsed,privacy:.public) ms.")
        return content
    }

    @MainActor func invalidateDisplayCache() { cachedDisplays.removeAll() }

    @MainActor func verifyAccess() async throws {
        let content = try await refreshAvailableContent()
        guard !content.displays.isEmpty else { throw AppError.message(L10n.text("No capturable display is available.")) }
        guard ownApplication != nil else { throw AppError.message(L10n.text("Cannot safely exclude Mac Duo from capture. Please reopen the app.")) }
    }

    @MainActor func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        guard !isRunning else { return }
        generation += 1
        let token = generation
        starting = true
        defer { if token == generation { starting = false } }
        let startedAt = ProcessInfo.processInfo.systemUptime
        var forceRefresh = cachedDisplays[displayID] == nil || ownApplication == nil
        for attempt in 0..<2 {
            let usedCache = !forceRefresh
            if forceRefresh {
                do { _ = try await refreshAvailableContent() }
                catch { guard token == generation else { return }; throw error }
            }
            guard token == generation else { return }
            guard let display = cachedDisplays[displayID] else {
                throw AppError.message(L10n.text("The built-in display is not available."))
            }
            // Exclude our own application explicitly, avoiding recursive capture of the overlay.
            guard let ownApplication else { throw AppError.message(L10n.text("Cannot safely exclude Mac Duo from capture. Please reopen the app.")) }
            let filter = SCContentFilter(display:display, excludingApplications:[ownApplication], exceptingWindows:[])
            logger.notice("Capture prepared with process exclusion; cached display: \(usedCache,privacy:.public); app active: \(NSApp.isActive,privacy:.public).")
            let config = SCStreamConfiguration()
            config.width = width; config.height = height
            config.minimumFrameInterval = CMTime(value:1,timescale:Int32(fps))
            config.queueDepth = 3
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false
            config.colorSpaceName = CGColorSpace.sRGB
            config.scalesToFit = true
            let newStream = SCStream(filter:filter,configuration:config,delegate:self)
            do {
                try newStream.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue)
                stream = newStream
                frames.acceptStream(ObjectIdentifier(newStream))
                try await newStream.startCapture()
                if token == generation {
                    let elapsed = Int((ProcessInfo.processInfo.systemUptime-startedAt)*1_000)
                    logger.notice("Live screen stream started after \(elapsed,privacy:.public) ms.")
                } else { try? await newStream.stopCapture() }
                return
            } catch {
                guard token == generation else { return }
                if stream === newStream { stream = nil;frames.invalidateStream() }
                if usedCache && attempt == 0 {
                    cachedDisplays.removeValue(forKey:displayID)
                    forceRefresh = true
                    logger.notice("Cached display start failed; refreshing shareable content once.")
                    continue
                }
                throw error
            }
        }
    }

    @MainActor func stop() {
        generation += 1; starting = false
        let previous = stream; stream = nil
        frames.invalidateStream()
        if let previous { Task { try? await previous.stopCapture() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]]
        guard let rawStatus = attachments?.first?[.status] as? Int, let status = SCFrameStatus(rawValue:rawStatus) else { return }
        let identity = ObjectIdentifier(stream)
        if status == .complete, let buffer = sampleBuffer.imageBuffer {
            // No per-frame main-queue block or buffer backlog. Identity and put
            // are atomic with stop(), so old callbacks cannot resurrect frames.
            if frames.put(buffer,from:identity) == true {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.stream === stream else { return }
                    self.logger.notice("First complete live desktop frame received.")
                    self.onFirstFrame?()
                }
            }
        } else if status == .blank || status == .suspended || status == .stopped {
            if frames.clear(from:identity) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.stream === stream else { return }
                    self.onUnavailable?()
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil; self.frames.invalidateStream()
            self.onFailure?(error.localizedDescription)
        }
    }
}
