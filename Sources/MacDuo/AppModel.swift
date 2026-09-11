import AppKit
import SwiftUI
import MetalKit
import Carbon
import FoldCore
import ScreenCaptureKit
import OSLog
import IOKit.ps

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    func localizedTitle(_ language: AppLanguage) -> String {
        AppLocalization.text(rawValue.capitalized, language: language)
    }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    var native: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named:.aqua)
        case .dark: return NSAppearance(named:.darkAqua)
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var lidAngle: Double?
    @Published var enabled = false
    @Published var checkingPermission = false
    @Published private(set) var status = ""
    @Published var language = AppLanguage.initial {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language.rawValue, forKey: "language")
            publishStatus()
            languageChanged?()
        }
    }
    @Published var hasPermission = CGPreflightScreenCaptureAccess()
    @Published var followLid = UserDefaults.standard.object(forKey:"followLid") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followLid,forKey:"followLid") }
    }
    @Published var appearance = AppAppearance(rawValue:UserDefaults.standard.string(forKey:"appearance") ?? "system") ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue,forKey:"appearance")
            NSApp.appearance = appearance.native
        }
    }
    /// Choosing an effect only saves and redraws. It never starts a full-screen demo.
    @Published var effect = FoldEffect.resolve(persisted:UserDefaults.standard.string(forKey:"effect")) {
        didSet {
            guard oldValue != effect else { return }
            UserDefaults.standard.set(effect.persistedIdentifier,forKey:"effect")
            wakePreview()
            update()
        }
    }
    @Published var previewAngle = 72.0
    @Published var clearAngle = UserDefaults.standard.object(forKey:"clearAngle") as? Double ?? 105 {
        didSet { UserDefaults.standard.set(clearAngle,forKey:"clearAngle") }
    }
    @Published var perspective = UserDefaults.standard.object(forKey:"perspective") as? Double ?? 0.7 {
        didSet { UserDefaults.standard.set(perspective,forKey:"perspective") }
    }
    @Published var blur = UserDefaults.standard.object(forKey:"blur") as? Double ?? 0.65 {
        didSet { UserDefaults.standard.set(blur,forKey:"blur") }
    }
    @Published var shadow = UserDefaults.standard.object(forKey:"shadow") as? Double ?? 0.65 {
        didSet { UserDefaults.standard.set(shadow,forKey:"shadow") }
    }
    @Published var clearWhenStill = UserDefaults.standard.object(forKey:"clearWhenStill") as? Bool ?? true {
        didSet {
            if oldValue != clearWhenStill {
                UserDefaults.standard.set(clearWhenStill,forKey:"clearWhenStill")
                resetStillness()
                updateStillnessStatus()
                update()
            }
        }
    }
    @Published private(set) var lidIsStill = false
    @Published var stillnessDelay = UserDefaults.standard.object(forKey:"stillnessDelay") as? Double ?? 2 {
        didSet { UserDefaults.standard.set(stillnessDelay,forKey:"stillnessDelay") }
    }
    @Published var demoRunning = false
    @Published var previewPlaying = false
    @Published var sensorAvailable = false
    @Published var overlayVisible = false
    @Published var fps = 60
    @Published var reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let sensor = LidSensor()
    let capture = DesktopCapture()
    let device = MTLCreateSystemDefaultDevice()
    var previewRenderer: FoldRenderer?
    weak var previewView: MTKView?
    private var renderer: FoldRenderer?
    private var panel: OverlayPanel?
    private var metalView: MTKView?
    private var timer: Timer?
    private var enableTask: Task<Void, Never>?
    private let logger = Logger(subsystem:"local.lidflow.mac",category:"lifecycle")
    private var hotKey: EventHotKeyRef?
    private var escapeKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var localKeyMonitor: Any?
    private var sessionActive = true
    private var systemAwake = true
    private var displayAwake = true
    private var sensorAt: TimeInterval = 0
    private var waitingForSensor = false
    private var stillness = LidStillness()
    private var liveAnimation = FoldAnimation()
    private var powerCheckedAt: TimeInterval = -.infinity
    private var demoStart: TimeInterval?
    private var previewStart: TimeInterval?
    private var idleSince: TimeInterval?
    private var screenID: CGDirectDisplayID?
    private var notifications: [NSObjectProtocol] = []
    private var syntheticCheckPath: String?
    private var presentedFrames = 0
    private var statusSource = "Preview is ready. Enable Mac Duo to use your desktop."
    var showWindow: (() -> Void)?
    var overlayVisibilityChanged: ((Bool) -> Void)?
    var languageChanged: (() -> Void)?

    init() {
        NSApp.appearance = appearance.native
        publishStatus()
        sensor.onReading = { [weak self] angle in
            guard let self else { return }
            if self.lidAngle != angle { self.lidAngle = angle }
            if self.sensorAvailable != (angle != nil) { self.sensorAvailable = angle != nil }
            self.sensorAt = ProcessInfo.processInfo.systemUptime
            let settled = self.stillness.observe(angle:angle,at:self.sensorAt,delay:self.stillnessDelay)
            if self.lidIsStill != settled {
                self.lidIsStill = settled
                self.updateStillnessStatus()
                if self.enabled && self.clearWhenStill && !self.demoRunning {
                    self.logger.notice("Lid stillness changed: \(settled,privacy:.public)")
                }
            }
            if angle == nil && self.enabled { self.pause("Lid sensor unavailable. Use the preview or reconnect the sensor.") }
            self.update()
        }
        capture.onFirstFrame = { [weak self] in self?.update() }
        capture.onUnavailable = { [weak self] in self?.hideOverlay() }
        capture.onFailure = { [weak self] reason in self?.pause("Capture stopped: \(reason)") }
        registerHotKey()
        sensor.start()
        timer = Timer(timeInterval:0.1,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer!,forMode:.common)
        observeWorkspace()
    }

    var previewProgress: Double {
        if let start = previewStart {
            let t = ProcessInfo.processInfo.systemUptime-start
            if t <= 5 { return FoldMath.progress(angle: demoAngle(t/5),clearAngle:clearAngle) }
        }
        if followLid { return liveProgress }
        return FoldMath.progress(angle:previewAngle,clearAngle:clearAngle)
    }

    /// Both Metal views use this clock in live mode, including the fade to clear.
    func animatedProgress(preview: Bool) -> Double? {
        if preview && (!followLid || previewPlaying) { return nil }
        return liveAnimation.sample(target:overlayVisible ? liveProgress : 0,
                                    at:ProcessInfo.processInfo.systemUptime)
    }

    func wakePreview() {
        if !overlayVisible { liveAnimation.prime(at:ProcessInfo.processInfo.systemUptime) }
        if let previewView { previewRenderer?.wake(previewView) }
    }

    private func updateFrameRate(at now: TimeInterval) {
        if now-powerCheckedAt >= 2 {
            powerCheckedAt = now
            let info = ProcessInfo.processInfo
            let externalPower: Bool
            if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
                externalPower = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? == kIOPSACPowerValue
            } else { externalPower = false }
            let rate = FoldFramePacing.rate(maximum:builtInScreen()?.maximumFramesPerSecond ?? 60,
                externalPower:externalPower,lowPower:info.isLowPowerModeEnabled,
                thermalPressure:info.thermalState == .serious || info.thermalState == .critical,moving:true)
            if fps != rate {
                fps = rate
                logger.notice("Motion refresh cap: \(rate) Hz; capture stays at most 60 Hz.")
            }
        }
        let rate = demoRunning || !lidIsStill ? fps : min(60,fps)
        if metalView?.preferredFramesPerSecond != rate { metalView?.preferredFramesPerSecond = rate }
    }

    func uniforms(preview: Bool) -> FoldUniforms {
        var u = FoldUniforms()
        u.progress = Float(preview ? previewProgress : liveProgress)
        u.perspective = Float(perspective);u.blur = Float(blur);u.shadow = Float(shadow)
        u.fadeOnly = reducedMotion ? 1 : 0
        u.effect = effect.shaderIndex // The desktop and its preview always share one selection.
        return u
    }

    private var demoDuration: Double { syntheticCheckPath == nil ? 8 : 20 }

    var liveProgress: Double {
        guard enabled,sessionActive,systemAwake,displayAwake,!waitingForSensor else { return 0 }
        if let start = demoStart {
            let t = min(1,(ProcessInfo.processInfo.systemUptime-start)/demoDuration)
            return FoldMath.progress(angle:demoAngle(t),clearAngle:clearAngle)
        }
        if shouldClearForStillness { return 0 }
        guard let angle = lidAngle else { return 0 }
        return FoldMath.progress(angle:angle,clearAngle:clearAngle)
    }

    private func demoAngle(_ t: Double) -> Double { clearAngle + 8 - sin(min(1,max(0,t)) * .pi) * (clearAngle-12) }

    private var shouldClearForStillness: Bool { clearWhenStill && lidIsStill && !demoRunning }

    private func resetStillness() { stillness.reset(); lidIsStill = false }

    private func updateStillnessStatus() {
        guard enabled, !demoRunning else { return }
        setStatus(shouldClearForStillness
            ? "Lid is still. Move it to animate again."
            : "Following your lid. Close it gently to see the effect.")
    }

    func text(_ key: String) -> String {
        AppLocalization.text(key, language: language)
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }

    func setStatus(_ english: String) {
        statusSource = english
        publishStatus()
    }

    private func publishStatus() {
        status = AppLocalization.dynamic(statusSource, language: language)
    }

    func enable(startDesktopTest: Bool = false) {
        guard !checkingPermission else { return }
        guard device != nil else { setStatus("This Mac does not have a supported Metal GPU.");return }
        guard sensorAvailable else { setStatus("No working lid angle sensor was found. The preview still works.");return }
        checkingPermission = true
        setStatus("Checking screen access…")
        enableTask = Task { [weak self] in
            guard let self else { return }
            defer { self.checkingPermission = false }
            do {
                // Ask the API we actually use. Core Graphics preflight can retain an old
                // permission result and must not block an otherwise authorized SCK session.
                try await capture.verifyAccess()
                guard !Task.isCancelled else { return }
                self.hasPermission = true
                self.enabled = true
                self.setStatus("Following your lid. Close it gently to see the effect.")
                self.updateStillnessStatus()
                self.logger.notice("Enable succeeded: ScreenCaptureKit access verified.")
                if startDesktopTest { self.beginDesktopTest() } else { self.update() }
            } catch {
                guard !Task.isCancelled else { return }
                self.enabled = false
                let failure = error as NSError
                if failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue {
                    self.hasPermission = false
                    self.setStatus("Screen access was not accepted. Allow the Mac Duo copy in Applications, then quit and reopen it. If its permission was already on for an older build, remove that old entry and add the current app.")
                } else {
                    self.setStatus("Could not enable screen capture: \(error.localizedDescription)")
                }
                self.logger.error("Enable failed: \(failure.domain,privacy:.public) / \(failure.code)")
            }
        }
    }

    func pause(_ message: String = "Paused. Your desktop is clear.") {
        logger.notice("Following paused: \(message,privacy:.public)")
        enableTask?.cancel();enableTask = nil;checkingPermission = false
        if let path = syntheticCheckPath {
            let report: [String:Any] = ["generatedArtworkOnly":true,"screenCaptureStarted":capture.isRunning,
                "drawnFrames":renderer?.drawnFrames ?? 0,"presentedFrames":presentedFrames,
                "skippedFrames":renderer?.skippedFrames ?? 0,"preferredFPS":metalView?.preferredFramesPerSecond ?? 0,
                "stopReason":message,"overlayWasVisible":overlayVisible,"gpuTimeMS":renderer?.lastGPUTimeMS ?? 0]
            if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
                try? data.write(to:URL(fileURLWithPath:path))
            }
            syntheticCheckPath = nil
        }
        enabled = false;demoStart = nil;demoRunning = false
        hideOverlay();capture.stop();setStatus(message)
    }

    func playPreview() { previewStart = ProcessInfo.processInfo.systemUptime;previewPlaying = true }

    func testDesktop() {
        if !enabled { enable(startDesktopTest:true);return }
        beginDesktopTest()
    }

    private func beginDesktopTest() {
        demoStart = ProcessInfo.processInfo.systemUptime;demoRunning = true
        setStatus("Eight-second desktop test. Press Esc to stop.")
        update()
    }

    /// Exercises the real overlay with generated pixels. Never requests or starts screen capture.
    func checkOverlay(output: String) {
        do {
            guard let screen = builtInScreen(), let device else { throw AppError.message("Built-in display or GPU unavailable.") }
            try prepareOverlay(on:screen)
            let factory = try FoldRenderer(device:device)
            capture.frames.put(try factory.makeSyntheticFrame())
            syntheticCheckPath = output;presentedFrames = 0
            enabled = true;demoStart = ProcessInfo.processInfo.systemUptime;demoRunning = true
            setStatus("Testing the overlay with generated artwork. Esc stops the test.")
            update()
        } catch { pause(error.localizedDescription) }
    }

    func openPrivacy() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func retrySensor() { sensor.stop();sensor.start() }

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(n.uint32Value) != 0 && CGDisplayIsActive(n.uint32Value) != 0
        }
    }

    private func prepareOverlay(on screen: NSScreen) throws {
        guard let device else { throw AppError.message("Metal is unavailable.") }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        if screenID != displayID || panel?.frame != screen.frame {
            hideOverlay();panel?.close();panel = nil;renderer = nil;metalView = nil;capture.stop()
        }
        screenID = displayID
        guard panel == nil else { return }
        let panel = OverlayPanel(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false,screen:screen)
        panel.level = NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.statusWindow))+1)
        panel.isOpaque = true;panel.backgroundColor = .black;panel.hasShadow = false
        panel.ignoresMouseEvents = true;panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.setFrame(screen.frame,display:false)
        let renderer = try FoldRenderer(device:device)
        renderer.frames = capture.frames
        renderer.parameters = { [weak self] in self?.uniforms(preview:false) ?? FoldUniforms() }
        renderer.animatedProgress = { [weak self] in self?.animatedProgress(preview:false) }
        renderer.onFailure = { [weak self] reason in self?.pause(reason) }
        renderer.onPresented = { [weak self] in
            guard let self, self.enabled, self.overlayVisible, self.capture.frames.get().0 != nil else { return }
            if self.panel?.alphaValue == 0 { self.logger.notice("Overlay presented a completed GPU frame.") }
            self.panel?.alphaValue = 1
            self.presentedFrames += 1
        }
        let view = MTKView(frame:NSRect(origin:.zero,size:screen.frame.size),device:device)
        renderer.configure(view);view.isPaused = true
        panel.contentView = view
        self.panel = panel;self.metalView = view;self.renderer = renderer
    }

    private func update() {
        let now = ProcessInfo.processInfo.systemUptime
        updateFrameRate(at:now)
        if !overlayVisible { liveAnimation.prime(at:now) }
        if let start = previewStart, now-start > 5 {
            previewStart = nil;previewPlaying = false;previewAngle = clearAngle+8
        }
        if let start = demoStart, now-start > demoDuration {
            if syntheticCheckPath != nil { pause("Synthetic overlay test completed.");return }
            demoStart = nil;demoRunning = false
            setStatus("Desktop test finished. Following your lid.")
            updateStillnessStatus()
            logger.notice("Desktop test completed; overlay is clearing.")
        }
        guard enabled, sessionActive, systemAwake, displayAwake else { return }
        if now-sensorAt > 1 {
                // Delivery gaps need not mean the HID device has disconnected.
                // Fail open immediately and resume when fresh readings arrive.
            hideOverlay()
            if capture.isRunning { capture.stop() }
            if !waitingForSensor {
                waitingForSensor = true
                setStatus("Waiting for the lid sensor. Your desktop is clear.")
                logger.notice("Sensor reports delayed: overlay cleared; awaiting fresh readings.")
            }
            return
        }
        if waitingForSensor {
            waitingForSensor = false;updateStillnessStatus()
            logger.notice("Fresh sensor reports received; automatic following resumed.")
        }
        guard let screen = builtInScreen(), let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGDisplayIsInMirrorSet(display.uint32Value) == 0 else {
            pause("Mac Duo needs an active, unmirrored built-in display.");return
        }
        let target = liveProgress
        let shouldCapture = demoRunning || (!shouldClearForStillness && (lidAngle ?? 180) < clearAngle+14)
        if shouldCapture {
            idleSince = nil
            do { try prepareOverlay(on:screen) } catch { pause(error.localizedDescription);return }
            if !capture.isRunning && syntheticCheckPath == nil {
                let width = Int(screen.frame.width*screen.backingScaleFactor)
                let height = Int(screen.frame.height*screen.backingScaleFactor)
                Task {
                    guard enabled,sessionActive,systemAwake,displayAwake,!shouldClearForStillness,
                          ProcessInfo.processInfo.systemUptime-sensorAt <= 1 else { return }
                    do { try await capture.start(displayID:display.uint32Value,width:width,height:height,fps:min(60,fps)) }
                    catch { if enabled { pause("Cannot capture the desktop: \(error.localizedDescription)") } }
                }
            }
        } else if capture.isRunning {
            if idleSince == nil { idleSince = now }
            if now-(idleSince ?? now) > 1.2 && !overlayVisible { capture.stop() }
        }
        if target > 0.0001, capture.frames.get().0 != nil {
            if !overlayVisible {
                // Require a working escape route before putting anything over the desktop.
                guard registerEscape() else { pause("Could not register Esc. Close other keyboard utilities and try again.");return }
                renderer?.resetProgress(to:0)
                liveAnimation.reset()
                panel?.alphaValue = 0
                overlayVisible = true
                overlayVisibilityChanged?(true)
                panel?.orderFrontRegardless()
                metalView?.isPaused = false
                // Reveal only after a textured frame completes on the GPU.
                if let metalView { renderer?.draw(in:metalView) }
            }
        } else if overlayVisible, (renderer?.progress ?? 0) < 0.0002 || capture.frames.get().0 == nil {
            hideOverlay()
        }
        if shouldClearForStillness && !overlayVisible && capture.isRunning {
            capture.stop(); idleSince = nil
            logger.notice("Stationary lid: overlay cleared and capture stopped.")
        }
    }

    private func hideOverlay() {
        panel?.orderOut(nil);panel?.alphaValue = 0;metalView?.isPaused = true
        overlayVisible = false
        liveAnimation.reset()
        overlayVisibilityChanged?(false)
        if let escapeKey { UnregisterEventHotKey(escapeKey);self.escapeKey = nil }
    }

    private func registerHotKey() {
        // App-targeted events (including keyboard accessibility tools) can bypass Carbon's
        // global hot-key dispatcher. Handle the same shortcuts in our local event queue.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let escape = event.keyCode == UInt16(kVK_Escape) && (self.overlayVisible || self.demoRunning)
            let chord = event.keyCode == UInt16(kVK_ANSI_F) && mods == [.control,.option,.command]
            if escape || chord {
                self.pause("Stopped with the keyboard shortcut. Your desktop is clear.")
                return nil
            }
            return event
        }
        var eventType = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _,_,context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                let model = Unmanaged<AppModel>.fromOpaque(context).takeUnretainedValue()
                model.pause("Stopped with the keyboard shortcut. Your desktop is clear.")
            }
            return noErr
        },1,&eventType,context,&hotKeyHandler)
        let id = EventHotKeyID(signature:0x4C464C57,id:1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_F),UInt32(controlKey|optionKey|cmdKey),id,GetApplicationEventTarget(),0,&hotKey)
        if result != noErr { setStatus("Global pause shortcut unavailable. Esc will remain available during the effect.") }
    }

    private func registerEscape() -> Bool {
        if escapeKey != nil { return true }
        let id = EventHotKeyID(signature:0x4C464C57,id:2)
        return RegisterEventHotKey(UInt32(kVK_Escape),0,id,GetApplicationEventTarget(),0,&escapeKey) == noErr
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        notifications.append(nc.addObserver(forName:NSWorkspace.activeSpaceDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Drop pixels from the previous Space and resume from a fresh frame.
                // Changing desktops never changes the user's enabled state.
                self.hideOverlay();self.capture.stop()
                self.logger.notice("Desktop changed; following remains enabled: \(self.enabled,privacy:.public).")
                self.update()
            }
        })
        let sleepEvents: [(Notification.Name, Int)] = [
            (NSWorkspace.willSleepNotification,0), (NSWorkspace.screensDidSleepNotification,1),
            (NSWorkspace.sessionDidResignActiveNotification,2)]
        let wakeEvents: [(Notification.Name, Int)] = [
            (NSWorkspace.didWakeNotification,0), (NSWorkspace.screensDidWakeNotification,1),
            (NSWorkspace.sessionDidBecomeActiveNotification,2)]
        for (name,kind) in sleepEvents {
            notifications.append(nc.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if kind == 0 { self.systemAwake = false }
                    if kind == 1 { self.displayAwake = false }
                    if kind == 2 { self.sessionActive = false }
                    self.resetStillness()
                    self.hideOverlay();self.capture.stop();self.sensor.stop()
                }
            })
        }
        for (name,kind) in wakeEvents {
            notifications.append(nc.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if kind == 0 { self.systemAwake = true }
                    if kind == 1 { self.displayAwake = true }
                    if kind == 2 { self.sessionActive = true }
                    // A display wake must not reactivate another user's session.
                    guard self.systemAwake,self.displayAwake,self.sessionActive else { return }
                    self.lidAngle = nil;self.sensorAt = ProcessInfo.processInfo.systemUptime
                    self.resetStillness();self.updateStillnessStatus()
                    self.sensor.start()
                }
            })
        }
        notifications.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideOverlay();self?.capture.stop();self?.panel?.close();self?.panel = nil;self?.screenID = nil }
        })
        notifications.append(nc.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        })
    }

    func shutdown() {
        pause();sensor.stop();timer?.invalidate()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }
}
