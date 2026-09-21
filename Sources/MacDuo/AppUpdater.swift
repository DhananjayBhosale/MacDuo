import AppKit
import CryptoKit
import FoldCore

/// One request only when the user asks. No scheduled checks, analytics, or updater daemon.
@MainActor final class AppUpdater: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var buttonTitle = L10n.text("Check for updates")
    private let releases = URL(string:"https://github.com/DhananjayBhosale/MacDuo/releases/latest")!

    func checkForUpdates() {
        guard !isBusy else { return }
        isBusy = true;buttonTitle = L10n.text("Checking…")
        Task {
            defer { isBusy = false;buttonTitle = L10n.text("Check for updates") }
            do {
                guard let update = try await Self.findUpdate() else {
                    show(L10n.text("You’re up to date"),message:L10n.format("Mac Duo %@ is the latest stable release.",Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? ""))
                    return
                }
                let alert = NSAlert()
                alert.messageText = L10n.format("Mac Duo %@ is available",update.tag)
                alert.informativeText = L10n.text("Download, verify, and install the update, then reopen Mac Duo. Your settings will be kept. macOS may ask you to allow the updated app or Screen Recording again.")
                alert.addButton(withTitle:L10n.text("Install & Relaunch"))
                alert.addButton(withTitle:L10n.text("Later"))
                alert.addButton(withTitle:L10n.text("View release"))
                NSApp.activate(ignoringOtherApps:true)
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    buttonTitle = L10n.text("Updating…")
                    let destination = try UpdateInstallation.installLocation()
                    let archive = try await UpdateDownload.fetch(update.archive,maximum:ReleaseUpdate.maximumArchiveBytes)
                    guard archive.count == update.archiveSize else { throw UpdateError.invalid("The installer download was incomplete. Please try again.") }
                    let checksums = try await UpdateDownload.fetch(update.checksums,maximum:16_384)
                    let job = try await Task.detached(priority:.utility) {
                        try UpdateInstallation.prepare(archive:archive,checksums:checksums,update:update,destination:destination)
                    }.value
                    // A detached helper waits for our normal shutdown before touching the bundle.
                    try await UpdateInstallation.startHelper(job)
                    NSApp.terminate(nil)
                case .alertThirdButtonReturn: NSWorkspace.shared.open(update.releasePage)
                default: break
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = L10n.text("Mac Duo could not update")
                alert.informativeText = L10n.text(error.localizedDescription)
                alert.addButton(withTitle:L10n.text("OK"));alert.addButton(withTitle:L10n.text("Open downloads"))
                NSApp.activate(ignoringOtherApps:true)
                if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(releases) }
            }
        }
    }

    static func findUpdate() async throws -> ReleaseUpdate? {
        let url = URL(string:"https://api.github.com/repos/\(ReleaseUpdate.repository)/releases/latest")!
        let data = try await UpdateDownload.fetch(url,maximum:1_048_576)
        return try ReleaseUpdate.newerRelease(data:data,installed:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "")
    }
    private func show(_ title: String, message: String) {
        let alert = NSAlert();alert.messageText = title;alert.informativeText = message
        NSApp.activate(ignoringOtherApps:true);alert.runModal()
    }
}

/// Reject untrusted redirects and enforce the byte limit while receiving, not afterwards.
private final class UpdateDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximum: Int
    private var received = Data()
    private var completion: CheckedContinuation<Data, Error>?
    private var failure: Error?
    private var session: URLSession?
    init(maximum: Int) { self.maximum = maximum }

    static func fetch(_ url: URL, maximum: Int) async throws -> Data {
        let download = UpdateDownload(maximum:maximum)
        return try await withCheckedThrowingContinuation { continuation in
            download.completion = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 180
            configuration.urlCache = nil;configuration.httpCookieStorage = nil
            let session = URLSession(configuration:configuration,delegate:download,delegateQueue:nil)
            download.session = session
            var request = URLRequest(url:url)
            request.setValue("MacDuo-Updater",forHTTPHeaderField:"User-Agent")
            request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
            session.dataTask(with:request).resume()
        }
    }
    private static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["api.github.com","github.com","release-assets.githubusercontent.com","objects.githubusercontent.com"].contains(url.host ?? "")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard Self.allowed(request.url) else {
            failure = UpdateError.invalid("GitHub redirected the download to an unexpected location.")
            completionHandler(nil);return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard Self.allowed(response.url), let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= maximum else {
            failure = UpdateError.invalid("GitHub could not provide the update. Check your connection and try again later.")
            completionHandler(.cancel);return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard received.count <= maximum-data.count else {
            failure = UpdateError.invalid("The update download exceeded its size limit.");dataTask.cancel();return
        }
        received.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = failure ?? error { completion?.resume(throwing:error) }
        else { completion?.resume(returning:received) }
        completion = nil;session.invalidateAndCancel();self.session = nil
    }
}

private struct UpdateJob: Codable, Sendable {
    let token: String
    let destination: String
    let staging: String
    let version: String
    let parentPID: Int32
    let executableHash: String
    let installAfterExit: Bool
    var folder: URL { UpdateInstallation.cache.appendingPathComponent(token,isDirectory:true) }
    var identity: UpdateBundleIdentity? {
        ReleaseVersion(version).map { UpdateBundleIdentity(bundleIdentifier:"local.lidflow.mac",version:$0,executableHash:executableHash) }
    }
}

private struct UpdateHelperReady: Codable {
    let processID: Int32
    let executableHash: String
}

enum UpdateInstallation {
    fileprivate static var cache: URL {
        FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("local.lidflow.mac/updates",isDirectory:true)
    }
    private static func hash(_ file: URL) throws -> String {
        SHA256.hash(data:try Data(contentsOf:file)).map { String(format:"%02x",$0) }.joined()
    }
    static func installLocation() throws -> URL {
        let destination = Bundle.main.bundleURL.standardizedFileURL
        let roots = [URL(fileURLWithPath:"/Applications",isDirectory:true),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications",isDirectory:true)]
        guard roots.contains(destination.deletingLastPathComponent()), destination.lastPathComponent == "Mac Duo.app",
              destination.resolvingSymlinksInPath() == destination,
              (try? destination.resourceValues(forKeys:[.volumeIsReadOnlyKey]).volumeIsReadOnly) == false,
              FileManager.default.isWritableFile(atPath:destination.path),
              FileManager.default.isWritableFile(atPath:destination.deletingLastPathComponent().path) else {
            throw UpdateError.invalid("Move Mac Duo to Applications and open it there before updating. If Applications needs an administrator password, install the downloaded update with Finder.")
        }
        return destination
    }
    fileprivate static func prepare(archive: Data, checksums: Data, update: ReleaseUpdate, destination: URL, installAfterExit: Bool = true) throws -> UpdateJob {
        try ReleaseUpdate.verifyChecksum(archive:archive,manifest:checksums)
        try UpdateArchive.validate(archive)
        let files = FileManager.default, token = UUID().uuidString
        let folder = cache.appendingPathComponent(token,isDirectory:true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".MacDuo-update-\(token)",isDirectory:true)
        try files.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        do {
            try files.createDirectory(at:staging,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            try UpdateArchive.extract(archive,into:staging)
            let candidate = staging.appendingPathComponent("Mac Duo.app",isDirectory:true)
            try validateBundle(candidate,version:update.version)
            // URLSession is not a browser download and does not add quarantine itself.
            // Preserve macOS's downloaded-app assessment when LaunchServices opens it.
            let quarantine = "0081;\(String(Int(Date().timeIntervalSince1970),radix:16));Mac Duo;\(token)"
            let marked = quarantine.withCString { value in
                setxattr(candidate.path,"com.apple.quarantine",value,strlen(value),0,0)
            }
            guard marked == 0 else { throw UpdateError.invalid("macOS could not mark the downloaded app for its normal security check. Please install it with Finder.") }
            let digest = try hash(candidate.appendingPathComponent("Contents/MacOS/MacDuo"))
            let job = UpdateJob(token:token,destination:destination.path,staging:staging.path,
                                version:update.tag,parentPID:ProcessInfo.processInfo.processIdentifier,executableHash:digest,installAfterExit:installAfterExit)
            try JSONEncoder().encode(job).write(to:folder.appendingPathComponent("job.json"),options:.atomic)
            let helper = folder.appendingPathComponent("Installer.app",isDirectory:true)
            try UpdateHandoff.writeHelperBundle(from:Bundle.main.bundleURL,to:helper)
            try command("/usr/bin/codesign",["--verify","--deep","--strict",helper.path])
            return job
        } catch {
            try? files.removeItem(at:staging);try? files.removeItem(at:folder);throw error
        }
    }
    @discardableResult fileprivate static func startHelper(_ job: UpdateJob) async throws -> Process {
        let helper = Process()
        helper.executableURL = job.folder.appendingPathComponent("Installer.app/Contents/MacOS/MacDuo")
        helper.arguments = ["--finish-update",job.token]
        helper.standardInput = FileHandle.nullDevice;helper.standardOutput = FileHandle.nullDevice;helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
            try await UpdateHandoff.waitUntilReady(isRunning:{ helper.isRunning }) {
                guard let data = try? Data(contentsOf:job.folder.appendingPathComponent("helper-ready.json")),
                      let ready = try? JSONDecoder().decode(UpdateHelperReady.self,from:data) else { return false }
                return ready.processID == helper.processIdentifier && ready.executableHash == job.executableHash
            }
            return helper
        }
        catch {
            if helper.isRunning { helper.terminate();try? await Task.sleep(nanoseconds:200_000_000) }
            if helper.isRunning { kill(helper.processIdentifier,SIGKILL) }
            try? FileManager.default.removeItem(atPath:job.staging)
            try? FileManager.default.removeItem(at:job.folder)
            throw error
        }
    }
    private static func command(_ path: String, _ arguments: [String]) throws {
        let process = Process();process.executableURL = URL(fileURLWithPath:path);process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice
        try process.run();process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw UpdateError.invalid("The downloaded app failed validation or could not be installed. Nothing was replaced.")
        }
    }
    private static func validateBundle(_ app: URL, version: ReleaseVersion,
                                       architecture: ReleaseArchitecture = .current) throws {
        let files = FileManager.default
        guard let walker = files.enumerator(at:app,includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey]) else {
            throw UpdateError.invalid("The installer contains no app.")
        }
        for case let entry as URL in walker {
            let values = try entry.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw UpdateError.invalid("The installer contains unsupported linked files.")
            }
        }
        let info = try PropertyListSerialization.propertyList(from:Data(contentsOf:app.appendingPathComponent("Contents/Info.plist")),format:nil) as? [String:Any]
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        let currentOS = ReleaseVersion("\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)")!
        guard info?["CFBundleIdentifier"] as? String == "local.lidflow.mac",
              info?["CFBundleExecutable"] as? String == "MacDuo",
              info?["CFBundlePackageType"] as? String == "APPL",
              let string = info?["CFBundleShortVersionString"] as? String, ReleaseVersion(string) == version,
              let minimum = info?["LSMinimumSystemVersion"] as? String, let minimumVersion = ReleaseVersion(minimum), minimumVersion <= currentOS else {
            throw UpdateError.invalid("The downloaded app has the wrong identity or version, or requires a newer macOS.")
        }
        let binary = app.appendingPathComponent("Contents/MacOS/MacDuo")
        guard files.isExecutableFile(atPath:binary.path) else { throw UpdateError.invalid("The downloaded app is not executable.") }
        let executableArchitecture = architecture == .arm64
            ? NSBundleExecutableArchitectureARM64 : NSBundleExecutableArchitectureX86_64
        guard Bundle(url:app)?.executableArchitectures?.contains(NSNumber(value:executableArchitecture)) == true else {
            throw UpdateError.invalid("The downloaded app does not support this Mac’s processor.")
        }
        try command("/usr/bin/codesign",["--verify","--deep","--strict",app.path])
    }
    private static func readJob(_ token: String) throws -> UpdateJob {
        guard UUID(uuidString:token)?.uuidString == token else { throw UpdateError.invalid("Invalid update handoff.") }
        let folder = cache.appendingPathComponent(token,isDirectory:true)
        guard folder.resolvingSymlinksInPath() == folder else { throw UpdateError.invalid("Invalid update location.") }
        let job = try JSONDecoder().decode(UpdateJob.self,from:Data(contentsOf:folder.appendingPathComponent("job.json")))
        let destination = URL(fileURLWithPath:job.destination,isDirectory:true)
        let roots = [URL(fileURLWithPath:"/Applications",isDirectory:true),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications",isDirectory:true)]
        guard job.token == token, job.parentPID > 1, roots.contains(destination.deletingLastPathComponent()),
              destination.lastPathComponent == "Mac Duo.app", destination.resolvingSymlinksInPath() == destination,
              job.staging == destination.deletingLastPathComponent().appendingPathComponent(".MacDuo-update-\(token)",isDirectory:true).path else {
            throw UpdateError.invalid("Invalid update destination.")
        }
        return job
    }
    /// Called before creating the app for the copied helper, which never opens a window.
    static func finishUpdate(token: String) -> Int32 {
        guard let job = try? readJob(token) else { return 1 }
        let destination = URL(fileURLWithPath:job.destination,isDirectory:true)
        let staging = URL(fileURLWithPath:job.staging,isDirectory:true)
        let candidate = staging.appendingPathComponent("Mac Duo.app",isDirectory:true)
        let backup = staging.appendingPathComponent("Previous.app",isDirectory:true)
        let files = FileManager.default
        var installed = false
        defer {
            // Keep the original app available if a filesystem error prevented restoration.
            if installed || (!files.fileExists(atPath:backup.path) && files.fileExists(atPath:destination.path)) {
                try? files.removeItem(at:staging);try? files.removeItem(at:job.folder)
            }
        }
        do {
            guard let version = ReleaseVersion(job.version), staging.resolvingSymlinksInPath() == staging else {
                throw UpdateError.invalid("The prepared update changed location.")
            }
            try validateBundle(candidate,version:version)
            guard try hash(candidate.appendingPathComponent("Contents/MacOS/MacDuo")) == job.executableHash else {
                throw UpdateError.invalid("The prepared update changed before the helper started.")
            }
            let acknowledgment = UpdateHelperReady(processID:ProcessInfo.processInfo.processIdentifier,executableHash:job.executableHash)
            try JSONEncoder().encode(acknowledgment).write(to:job.folder.appendingPathComponent("helper-ready.json"),options:.atomic)
            let deadline = Date().addingTimeInterval(30)
            while kill(job.parentPID,0) == 0, Date() < deadline { Thread.sleep(forTimeInterval:0.1) }
            guard job.installAfterExit, kill(job.parentPID,0) != 0 else { return 1 }
            try validateBundle(candidate,version:version)
            let oldInfo = try PropertyListSerialization.propertyList(from:Data(contentsOf:destination.appendingPathComponent("Contents/Info.plist")),format:nil) as? [String:Any]
            guard try hash(candidate.appendingPathComponent("Contents/MacOS/MacDuo")) == job.executableHash,
                  oldInfo?["CFBundleIdentifier"] as? String == "local.lidflow.mac",
                  let old = oldInfo?["CFBundleShortVersionString"] as? String, let oldVersion = ReleaseVersion(old), oldVersion < version else {
                throw UpdateError.invalid("The installed app changed while the update was downloading.")
            }
            try UpdateReplacement.install(staged:candidate,destination:destination,backup:backup) {
                let ready = job.folder.appendingPathComponent("ready")
                try launchWithRecovery(destination,arguments:{ ["--update-ready",token] },ready:ready,identity:job.identity) { error in
                    showRecovery(error: error, destination:destination, ready:ready)
                }
            }
            installed = true
            return 0
        } catch {
            if kill(job.parentPID,0) != 0 {
                if files.fileExists(atPath:backup.path) {
                    // Launch the retained original itself; the alert points to its recovery location.
                    try? command("/usr/bin/open",[backup.path,"--args","--update-needs-recovery"])
                } else if files.fileExists(atPath:destination.path) {
                    try? command("/usr/bin/open",[destination.path,"--args","--update-rolled-back"])
                }
            }
            return 1
        }
    }
    /// Stages a supplied, verified package and observes the real helper's acknowledgment.
    /// The diagnostic job cannot replace the app, even if its parent is interrupted.
    static func checkHandoff(archive: URL, manifest: URL, version: String) async throws {
        let destination = try installLocation()
        guard let parsed = ReleaseVersion(version), parsed > ReleaseVersion("0.0")!,
              (try archive.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= ReleaseUpdate.maximumArchiveBytes,
              (try manifest.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 16_384 else {
            throw UpdateError.invalid("Invalid handoff verification package.")
        }
        let tag = version.hasPrefix("v") ? version : "v"+version
        let data = try Data(contentsOf:archive), checksums = try Data(contentsOf:manifest)
        let names = [(ReleaseUpdate.archiveName,data.count),(ReleaseUpdate.checksumName,checksums.count)]
        let assets: [[String:Any]] = names.map { ["name":$0.0,"size":$0.1,"browser_download_url":"https://github.com/\(ReleaseUpdate.repository)/releases/download/\(tag)/\($0.0)"] }
        let metadata = try JSONSerialization.data(withJSONObject:["tag_name":tag,"draft":false,"prerelease":false,"assets":assets])
        guard let update = try ReleaseUpdate.newerRelease(data:metadata,installed:"0.0") else { throw UpdateError.invalid("Invalid handoff verification version.") }
        let job = try prepare(archive:data,checksums:checksums,update:update,destination:destination,installAfterExit:false)
        defer {
            try? FileManager.default.removeItem(atPath:job.staging)
            try? FileManager.default.removeItem(at:job.folder)
        }
        let helper = try await startHelper(job)
        helper.terminate();try? await Task.sleep(nanoseconds:200_000_000)
        if helper.isRunning { kill(helper.processIdentifier,SIGKILL);try? await Task.sleep(nanoseconds:200_000_000) }
        guard !helper.isRunning, kill(job.parentPID,0) == 0 else { throw UpdateError.invalid("The diagnostic helper could not stop normally.") }
        try? FileManager.default.removeItem(atPath:job.staging)
        try? FileManager.default.removeItem(at:job.folder)
        guard !FileManager.default.fileExists(atPath:job.staging), !FileManager.default.fileExists(atPath:job.folder.path) else {
            throw UpdateError.invalid("The handoff succeeded, but its scratch files could not be removed.")
        }
        print("Helper handoff verified: PID \(helper.processIdentifier), SHA-256 \(job.executableHash); helper stopped, parent alive, replacement disabled, staging cleaned.")
    }
    @discardableResult private static func launchWithRecovery(_ destination: URL, arguments: () -> [String], ready: URL, identity: UpdateBundleIdentity? = nil,
                                                              recover: (Error) -> Bool) throws -> NSRunningApplication {
        while true {
            do { return try launchAndConfirm(destination,arguments:arguments(),ready:ready,identity:identity) }
            catch { guard recover(error) else { throw error } }
        }
    }
    private static func showRecovery(error: Error, destination: URL, ready: URL) -> Bool {
        let app = NSApplication.shared;app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps:true)
        while true {
            if FileManager.default.fileExists(atPath:ready.path) { return true }
            let alert = NSAlert()
            alert.messageText = L10n.text("macOS could not open the update")
            alert.informativeText = L10n.format("Your previous Mac Duo is safely backed up. If macOS blocked this downloaded app, go to System Settings → Privacy & Security → Open Anyway, approve Mac Duo there, then try opening it again. You can restore the previous version at any time.\n\n%@",L10n.text(error.localizedDescription))
            alert.addButton(withTitle:L10n.text("Restore Previous"))
            alert.addButton(withTitle:L10n.text("Open Privacy & Security"))
            alert.addButton(withTitle:L10n.text("Try Opening Again"))
            // This timer exists only inside this explicit recovery dialog. It recognizes
            // a launch approved in System Settings, then stops immediately with the dialog.
            let timer = Timer(timeInterval:0.5,repeats:true) { _ in
                if FileManager.default.fileExists(atPath:ready.path) { NSApp.abortModal() }
            }
            timer.tolerance = 0.1;RunLoop.main.add(timer,forMode:.modalPanel)
            let response = alert.runModal();timer.invalidate()
            if FileManager.default.fileExists(atPath:ready.path) { return true }
            switch response {
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?General")!)
            case .alertThirdButtonReturn: return true
            default: return false
            }
        }
    }
    private static func matches(_ bundle: Bundle, identity: UpdateBundleIdentity) -> Bool {
        guard bundle.bundleIdentifier == identity.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String,
              ReleaseVersion(version) == identity.version,
              let executable = bundle.executableURL, let digest = try? hash(executable) else { return false }
        return identity.matches(bundleIdentifier:bundle.bundleIdentifier,
                                version:bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String,
                                executableHash:digest)
    }
    @discardableResult private static func launchAndConfirm(_ destination: URL, arguments: [String], ready: URL, identity: UpdateBundleIdentity? = nil) throws -> NSRunningApplication {
        if FileManager.default.fileExists(atPath:ready.path),
           let existing = NSWorkspace.shared.runningApplications.first(where:{ application in
               guard !application.isTerminated, let url = application.bundleURL else { return false }
               if let identity {
                   guard application.bundleIdentifier == identity.bundleIdentifier, let bundle = Bundle(url:url) else { return false }
                   return matches(bundle,identity:identity)
               }
               return url.standardizedFileURL == destination.standardizedFileURL
           }) {
            return existing
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        var application: NSRunningApplication?, launchError: Error?, responded = false
        NSWorkspace.shared.openApplication(at:destination,configuration:configuration) { app, error in
            DispatchQueue.main.async { application = app;launchError = error;responded = true }
        }
        let timeout = Date().addingTimeInterval(60)
        while !responded, Date() < timeout { RunLoop.current.run(until:Date().addingTimeInterval(0.1)) }
        if let launchError { throw launchError }
        guard let application else { throw UpdateError.invalid(L10n.text("macOS could not open the update. Please install the downloaded app with Finder.")) }
        while !application.isTerminated, !FileManager.default.fileExists(atPath:ready.path), Date() < timeout {
            RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        }
        guard !application.isTerminated, FileManager.default.fileExists(atPath:ready.path) else {
            if !application.isTerminated {
                application.terminate();RunLoop.current.run(until:Date().addingTimeInterval(0.5))
                if !application.isTerminated { application.forceTerminate() }
            }
            throw UpdateError.invalid("The updated app did not finish opening. Your previous version is safely backed up.")
        }
        return application
    }
    /// Explicit diagnostics only: never chooses the installed app as an output location.
    static func checkPackage(archive: URL, manifest: URL, version: String, output: URL) throws {
        let folder = output.standardizedFileURL
        guard folder.path == output.path, !folder.path.hasPrefix("/Applications/"),
              !folder.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path+"/"),
              !FileManager.default.fileExists(atPath:folder.path), let version = ReleaseVersion(version) else {
            throw UpdateError.invalid("Choose a new scratch directory outside Applications for package verification.")
        }
        guard let architecture = ReleaseArchitecture(archiveName:archive.lastPathComponent) else {
            throw UpdateError.invalid("Use the canonical Mac-Duo-mac.zip or Mac-Duo-Intel.zip archive name for package verification.")
        }
        let archiveSize = try archive.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        let manifestSize = try manifest.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard archiveSize <= ReleaseUpdate.maximumArchiveBytes, manifestSize <= 16_384 else { throw UpdateError.invalid("Package verification input exceeds the download limits.") }
        let data = try Data(contentsOf:archive)
        try ReleaseUpdate.verifyChecksum(archive:data,manifest:Data(contentsOf:manifest),architecture:architecture)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            try UpdateArchive.extract(data,into:folder)
            try validateBundle(folder.appendingPathComponent("Mac Duo.app",isDirectory:true),version:version,
                               architecture:architecture)
        } catch { try? FileManager.default.removeItem(at:folder);throw error }
    }

    /// Uses disposable apps to exercise the same replacement and LaunchServices
    /// readiness functions as a real update, including restoration after launch failure.
    static func checkInstallerFixture(output: URL) throws {
        let files = FileManager.default, folder = output.standardizedFileURL
        guard folder.path == output.path, folder.lastPathComponent.hasPrefix("MacDuo-update-fixture-"),
              folder.resolvingSymlinksInPath() == folder,
              !folder.path.hasPrefix("/Applications/"), !folder.path.contains("/Applications/"),
              !files.fileExists(atPath:folder.path), let executable = Bundle.main.executableURL else {
            throw UpdateError.invalid("Choose a new scratch directory named MacDuo-update-fixture-… outside Applications.")
        }
        try files.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        func bundle(_ name: String, marker: String) throws -> URL {
            let app = folder.appendingPathComponent(name,isDirectory:true)
            let macOS = app.appendingPathComponent("Contents/MacOS",isDirectory:true)
            try files.createDirectory(at:macOS,withIntermediateDirectories:true)
            try files.copyItem(at:executable,to:macOS.appendingPathComponent("MacDuo"))
            try files.createDirectory(at:app.appendingPathComponent("Contents/Resources",isDirectory:true),withIntermediateDirectories:true)
            let info: [String:Any] = ["CFBundleIdentifier":"local.lidflow.mac.update-fixture", "CFBundleExecutable":"MacDuo",
                                     "CFBundleName":"Mac Duo Update Fixture", "CFBundlePackageType":"APPL", "LSUIElement":true,
                                     "CFBundleShortVersionString":"0.0.1", "CFBundleVersion":"1", "LSMinimumSystemVersion":"13.0"]
            try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
            try Data(marker.utf8).write(to:app.appendingPathComponent("Contents/Resources/fixture-version"))
            try command("/usr/bin/codesign",["--force","--sign","-",app.path])
            return app
        }
        let destination = try bundle("Mac Duo.app",marker:"old")
        let helper = folder.appendingPathComponent("Installer.app",isDirectory:true)
        try UpdateHandoff.writeHelperBundle(from:destination,to:helper)
        try command("/usr/bin/codesign",["--verify","--deep","--strict",helper.path])
        let bootstrap = Process();bootstrap.executableURL = helper.appendingPathComponent("Contents/MacOS/MacDuo")
        // Exercise the real bundle-copy helper path with sealed Info.plist/resources.
        // No job exists for this UUID, so no installation target can be modified.
        bootstrap.arguments = ["--finish-update",UUID().uuidString]
        bootstrap.standardOutput = FileHandle.nullDevice;bootstrap.standardError = FileHandle.nullDevice
        try bootstrap.run();bootstrap.waitUntilExit()
        guard bootstrap.terminationReason == .exit, bootstrap.terminationStatus == 1 else {
            throw UpdateError.invalid("The signed helper bundle could not start normally.")
        }
        let candidate = try bundle("Candidate.app",marker:"new")
        let backup = folder.appendingPathComponent("Backup.app",isDirectory:true), ready = folder.appendingPathComponent("ready")
        var application: NSRunningApplication?
        defer {
            if let application, !application.isTerminated { application.forceTerminate() }
        }
        try UpdateReplacement.install(staged:candidate,destination:destination,backup:backup) {
            application = try launchAndConfirm(destination,arguments:["--update-fixture-ready",ready.path],ready:ready)
        }
        guard try String(contentsOf:destination.appendingPathComponent("Contents/Resources/fixture-version"),encoding:.utf8) == "new",
              try String(contentsOf:backup.appendingPathComponent("Contents/Resources/fixture-version"),encoding:.utf8) == "old" else {
            throw UpdateError.invalid("Fixture replacement did not preserve the expected versions.")
        }
        let identity = UpdateBundleIdentity(bundleIdentifier:"local.lidflow.mac.update-fixture",version:ReleaseVersion("0.0.1")!,
                                           executableHash:try hash(destination.appendingPathComponent("Contents/MacOS/MacDuo")))
        let recognized = try launchAndConfirm(folder.appendingPathComponent("SimulatedTranslocation.app",isDirectory:true),
                                             arguments:[],ready:ready,identity:identity)
        guard recognized.processIdentifier == application?.processIdentifier else {
            throw UpdateError.invalid("Fixture did not recognize the already approved app at a different path.")
        }
        application?.terminate();RunLoop.current.run(until:Date().addingTimeInterval(0.5))
        if let application, !application.isTerminated { application.forceTerminate() }
        try files.removeItem(at:backup);try files.removeItem(at:ready)
        let failed = try bundle("Failed.app",marker:"failed")
        var rolledBack = false
        do {
            try UpdateReplacement.install(staged:failed,destination:destination,backup:backup) {
                try launchAndConfirm(destination,arguments:["--update-fixture-fail"],ready:ready)
            }
        } catch { rolledBack = true }
        guard rolledBack, try String(contentsOf:destination.appendingPathComponent("Contents/Resources/fixture-version"),encoding:.utf8) == "new",
              try String(contentsOf:failed.appendingPathComponent("Contents/Resources/fixture-version"),encoding:.utf8) == "failed",
              !files.fileExists(atPath:backup.path) else { throw UpdateError.invalid("Fixture failed to restore the previous version.") }
        var retries = 0
        try UpdateReplacement.install(staged:failed,destination:destination,backup:backup) {
            application = try launchWithRecovery(destination,arguments:{ retries == 0 ? ["--update-fixture-fail"] : ["--update-fixture-ready",ready.path] },ready:ready) { _ in
                retries += 1;return retries == 1
            }
        }
        guard retries == 1, try String(contentsOf:destination.appendingPathComponent("Contents/Resources/fixture-version"),encoding:.utf8) == "failed" else {
            throw UpdateError.invalid("Fixture recovery did not retry the validated candidate.")
        }
        try Data("{\"helperBootstrap\":true,\"launchServices\":true,\"readyHandshake\":true,\"replacement\":true,\"failedLaunchRollback\":true,\"explicitRecoveryRetry\":true,\"pathIndependentIdentity\":true}\n".utf8)
            .write(to:folder.appendingPathComponent("result.json"))
    }
    @MainActor static func confirmRelaunch() {
        var jobs: [UpdateJob] = []
        if let index = CommandLine.arguments.firstIndex(of:"--update-ready"), index+1 < CommandLine.arguments.count,
           let job = try? readJob(CommandLine.arguments[index+1]) {
            jobs = [job]
        } else {
            // Open Anyway can launch the app without our command-line handoff.
            // Recognize only matching pending jobs, once at launch, without network work.
            let folders = (try? FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil)) ?? []
            jobs = folders.prefix(16).compactMap { try? readJob($0.lastPathComponent) }
        }
        if !jobs.isEmpty {
            let bundleIdentifier = Bundle.main.bundleIdentifier
            let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String
            let executableHash = Bundle.main.executableURL.flatMap { try? hash($0) }
            for job in jobs {
                guard let identity = job.identity, let executableHash,
                      identity.matches(bundleIdentifier:bundleIdentifier,version:version,executableHash:executableHash) else { continue }
                try? Data("ready".utf8).write(to:job.folder.appendingPathComponent("ready"),options:.atomic)
            }
        }
        if CommandLine.arguments.contains("--update-rolled-back") {
            let alert = NSAlert();alert.messageText = L10n.text("The previous Mac Duo was restored")
            alert.informativeText = L10n.text("The update could not finish opening. You can keep using this version or install the latest release from GitHub.")
            NSApp.activate(ignoringOtherApps:true);alert.runModal()
        }
        if CommandLine.arguments.contains("--update-needs-recovery") {
            let alert = NSAlert();alert.messageText = L10n.text("Mac Duo kept your previous app safe")
            alert.informativeText = L10n.format("A file permission or disk error prevented the update from finishing. Your previous app is at:\n%@\nMove it back to Applications with Finder.",Bundle.main.bundleURL.path)
            NSApp.activate(ignoringOtherApps:true);alert.runModal()
        }
    }
}
