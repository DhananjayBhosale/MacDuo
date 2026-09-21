import AppKit
import SwiftUI
import FoldCore
import OSLog

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    var model: AppModel!
    private let updater = AppUpdater()
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var screenObserver: NSObjectProtocol?
    private let logger = Logger(subsystem:"local.lidflow.mac",category:"settings")
    private let launchLogger = Logger(subsystem:"local.lidflow.mac",category:"launch")
    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchStartedAt = ProcessInfo.processInfo.systemUptime
        model = AppModel()
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:940,height:528),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.delegate = self
        window.title = "Mac Duo"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.fullScreenNone]
        window.isReleasedWhenClosed = false
        screenObserver = NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitSettingsWindow() }
        }
        model.showWindow = { [weak self] in self?.showSettings() }
        model.overlayVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            self.updateSettingsLevel()
            if visible {
                self.logger.notice("Effect shown; settings level: \(self.window.level.rawValue); app active: \(NSApp.isActive,privacy:.public); settings on current desktop: \(self.window.isOnActiveSpace,privacy:.public).")
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        statusItem.button?.image = AppBrand.menuBarMark
        statusItem.button?.toolTip = L10n.text("Mac Duo — your desktop follows your lid")
        let menu = NSMenu();menu.delegate = self;statusItem.menu = menu
        statusItem.isVisible = model.showInMenuBar
        model.menuBarVisibilityChanged = { [weak self] visible in self?.statusItem.isVisible = visible }
        let appMenu = NSMenu()
        let appItem = NSMenuItem();appMenu.addItem(appItem)
        let submenu = NSMenu();submenu.addItem(effectItem());submenu.addItem(appearanceItem());submenu.addItem(updateItem());submenu.addItem(.separator())
        submenu.addItem(withTitle:L10n.text("Quit Mac Duo"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu = submenu;NSApp.mainMenu = appMenu
        UpdateInstallation.confirmRelaunch()
        let shellMilliseconds = Int((ProcessInfo.processInfo.systemUptime-launchStartedAt)*1_000)
        launchLogger.notice("Launch shell ready after \(shellMilliseconds,privacy:.public) ms; settings content deferred one main-queue turn.")
        DispatchQueue.main.async { [weak self] in self?.finishSettingsLaunch(startedAt:launchStartedAt) }
        if let index = CommandLine.arguments.firstIndex(of:"--overlay-check"), index+1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index+1]
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self] in self?.model.checkOverlay(output:path) }
        }
        if CommandLine.arguments.contains("--enable") {
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self] in self?.model.enable() }
        }
    }
    private func finishSettingsLaunch(startedAt: TimeInterval) {
        let content = NSHostingView(rootView:Controls(model:model,updater:updater))
        // The window owns its size. SwiftUI's ideal content height must never
        // stretch it to the screen edges; every control stays visible beside the preview.
        content.sizingOptions = []
        window.contentView = content
        fitSettingsWindow(center:true)
        showSettings()
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime-startedAt)*1_000)
        launchLogger.notice("Settings window ready after \(milliseconds,privacy:.public) ms.")
    }
    private var floatingBounds: NSRect {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x:0,y:0,width:1024,height:768)
        return visible.insetBy(dx:32,dy:32)
    }

    private func fitSettingsWindow(center: Bool = false) {
        let bounds = floatingBounds
        window.minSize = NSSize(width:min(900,bounds.width),height:min(530,bounds.height))
        window.maxSize = bounds.size
        var frame = window.frame
        frame.size = NSSize(width:min(center ? 940 : frame.width,bounds.width),height:min(center ? 550 : frame.height,bounds.height))
        if center {
            frame.origin = NSPoint(x:bounds.midX-frame.width/2,y:bounds.midY-frame.height/2)
        } else {
            frame.origin.x = min(max(frame.minX,bounds.minX),bounds.maxX-frame.width)
            frame.origin.y = min(max(frame.minY,bounds.minY),bounds.maxY-frame.height)
        }
        if window.frame != frame { window.setFrame(frame,display:true) }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width:min(frameSize.width,floatingBounds.width),height:min(frameSize.height,floatingBounds.height))
    }
    func windowDidEndLiveResize(_ notification: Notification) { fitSettingsWindow() }
    func windowDidChangeScreen(_ notification: Notification) { fitSettingsWindow() }
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let bounds = floatingBounds
        let size = NSSize(width:min(940,bounds.width),height:min(550,bounds.height))
        return NSRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height)
    }
    @objc func showSettings() { fitSettingsWindow();NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil);model.wakePreview() }
    private func updateSettingsLevel() {
        guard let window, let model else { return }
        // Keep controls readable only while the user is actually using them.
        // Lid movement must never raise an inactive window over another app.
        let elevated = model.overlayVisible && NSApp.isActive && window.isKeyWindow && window.isOnActiveSpace
        let level = elevated ? NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.statusWindow))+2) : .normal
        if window.level != level {
            window.level = level
            logger.notice("Settings level changed; elevated: \(elevated,privacy:.public); app active: \(NSApp.isActive,privacy:.public).")
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { updateSettingsLevel();model.refreshLaunchAtLogin() }
    func applicationDidResignActive(_ notification: Notification) { window?.level = .normal }
    func windowDidBecomeKey(_ notification: Notification) { updateSettingsLevel() }
    func windowDidResignKey(_ notification: Notification) { window?.level = .normal }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window.occlusionState.contains(.visible) { model.wakePreview() }
        else { model.previewView?.isPaused = true }
    }
    func windowWillClose(_ notification:Notification) {
        model.previewView?.isPaused = true
        model.previewView?.releaseDrawables()
        model.previewRenderer?.releaseTransientResources()
    }
    @objc func toggleEffect() { if model.enabled { model.pause() } else { model.enable() } }
    @objc func testEffect() { model.testDesktop() }
    @objc private func checkForUpdates() { updater.checkForUpdates() }
    private func updateItem() -> NSMenuItem {
        let item = NSMenuItem(title:L10n.text("Check for Updates…"),action:#selector(checkForUpdates),keyEquivalent:"")
        item.target = self;item.isEnabled = !updater.isBusy
        item.image = NSImage(systemSymbolName:"arrow.triangle.2.circlepath",accessibilityDescription:nil)
        return item
    }
    @objc private func toggleLaunchAtLogin() { model.setLaunchAtLogin(!model.launchAtLogin) }
    // Reachable only while the icon is visible, so this always hides in practice.
    // Show the window as the icon leaves, keeping the switch that restores it on screen.
    @objc private func toggleMenuBarIcon() {
        model.showInMenuBar.toggle()
        if !model.showInMenuBar { showSettings() }
    }
    @objc private func setAppearance(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let appearance = AppAppearance(rawValue:rawValue) else { return }
        model.appearance = appearance
    }
    @objc private func setEffect(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        // Selecting an effect saves it and redraws. It starts no full-screen test.
        model.effect = FoldEffect.resolve(persisted:rawValue)
    }
    private func effectItem() -> NSMenuItem {
        let item = NSMenuItem(title:L10n.text("Effect"),action:nil,keyEquivalent:"")
        item.image = NSImage(systemSymbolName:model.effect.symbol,accessibilityDescription:nil)
        let menu = NSMenu(title:L10n.text("Effect"));menu.identifier = NSUserInterfaceItemIdentifier("effect");menu.delegate = self
        for effect in FoldEffect.allCases {
            let option = menu.addItem(withTitle:L10n.text(effect.title),action:#selector(setEffect(_:)),keyEquivalent:"")
            option.target = self;option.representedObject = effect.persistedIdentifier
            option.toolTip = L10n.text(effect.summary)
            option.state = model.effect == effect ? .on : .off
        }
        item.submenu = menu
        return item
    }
    private func appearanceItem() -> NSMenuItem {
        let item = NSMenuItem(title:L10n.text("Appearance"),action:nil,keyEquivalent:"")
        item.image = NSImage(systemSymbolName:"circle.lefthalf.filled",accessibilityDescription:nil)
        let menu = NSMenu(title:L10n.text("Appearance"));menu.identifier = NSUserInterfaceItemIdentifier("appearance");menu.delegate = self
        for appearance in AppAppearance.allCases {
            let option = menu.addItem(withTitle:appearance.title,action:#selector(setAppearance(_:)),keyEquivalent:"")
            option.target = self;option.representedObject = appearance.rawValue
            option.state = model.appearance == appearance ? .on : .off
        }
        item.submenu = menu
        return item
    }
    func menuWillOpen(_ menu:NSMenu) {
        if menu.identifier?.rawValue == "appearance" {
            for item in menu.items { item.state = item.representedObject as? String == model.appearance.rawValue ? .on : .off }
            return
        }
        if menu.identifier?.rawValue == "effect" {
            for item in menu.items {
                item.state = item.representedObject as? String == model.effect.persistedIdentifier ? .on : .off
            }
            return
        }
        menu.removeAllItems()
        model.refreshLaunchAtLogin()
        let state = NSMenuItem(title:model.lidAngle.map{L10n.format("Lid angle: %.0f°",$0)} ?? L10n.text("Sensor unavailable"),action:nil,keyEquivalent:"")
        state.isEnabled = false;menu.addItem(state)
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle:model.enabled ? L10n.text("Pause Mac Duo") : L10n.text("Enable Mac Duo"),action:#selector(toggleEffect),keyEquivalent:"");toggle.target = self
        let settings = menu.addItem(withTitle:L10n.text("Open Mac Duo…"),action:#selector(showSettings),keyEquivalent:",");settings.target = self
        let test = menu.addItem(withTitle:L10n.text("Test desktop for 8 seconds"),action:#selector(testEffect),keyEquivalent:"");test.target = self
        menu.addItem(effectItem())
        menu.addItem(appearanceItem())
        menu.addItem(updateItem())
        let icon = menu.addItem(withTitle:L10n.text("Show menu bar icon"),action:#selector(toggleMenuBarIcon),keyEquivalent:"")
        icon.target = self
        icon.state = model.showInMenuBar ? .on : .off
        let login = menu.addItem(withTitle:L10n.text("Open at login"),action:#selector(toggleLaunchAtLogin),keyEquivalent:"")
        login.target = self
        login.state = model.launchAtLogin ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle:L10n.text("Quit Mac Duo"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool { showSettings();return true }
    func applicationWillTerminate(_ notification:Notification) {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        model.shutdown()
    }
}

MainActor.assumeIsolated {
if let index = CommandLine.arguments.firstIndex(of:"--update-handoff-check"), index+3 < CommandLine.arguments.count {
    Task {
        do {
            try await UpdateInstallation.checkHandoff(archive:URL(fileURLWithPath:CommandLine.arguments[index+1]),
                                                     manifest:URL(fileURLWithPath:CommandLine.arguments[index+2]),version:CommandLine.arguments[index+3])
            exit(0)
        } catch { fputs("Handoff check failed: \(error.localizedDescription)\n",stderr);exit(1) }
    }
    dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(of:"--update-package-check"), index+4 < CommandLine.arguments.count {
    do {
        try UpdateInstallation.checkPackage(archive:URL(fileURLWithPath:CommandLine.arguments[index+1]),
                                            manifest:URL(fileURLWithPath:CommandLine.arguments[index+2]),
                                            version:CommandLine.arguments[index+3],output:URL(fileURLWithPath:CommandLine.arguments[index+4],isDirectory:true))
        print("Package checksum, bounded extraction, bundle identity, version, macOS, architecture, and internal code-signature consistency verified; publisher authenticity is not established.");exit(0)
    } catch { fputs("Package check failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--update-installer-fixture"), index+1 < CommandLine.arguments.count {
    do { try UpdateInstallation.checkInstallerFixture(output:URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true));print("Installer fixture passed: LaunchServices, ready handshake, replacement, and failed-launch rollback.");exit(0) }
    catch { fputs("Installer fixture failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if CommandLine.arguments.contains("--update-fixture-fail"), Bundle.main.bundleIdentifier == "local.lidflow.mac.update-fixture" { exit(42) }
if let index = CommandLine.arguments.firstIndex(of:"--update-fixture-ready"), index+1 < CommandLine.arguments.count,
   Bundle.main.bundleIdentifier == "local.lidflow.mac.update-fixture" {
    let ready = URL(fileURLWithPath:CommandLine.arguments[index+1])
    guard ready.lastPathComponent == "ready", ready.deletingLastPathComponent().lastPathComponent.hasPrefix("MacDuo-update-fixture-"),
          ready.deletingLastPathComponent() == Bundle.main.bundleURL.deletingLastPathComponent() else { exit(1) }
    do { try Data("ready".utf8).write(to:ready,options:.withoutOverwriting) } catch { exit(1) }
    let app = NSApplication.shared;app.setActivationPolicy(.accessory);app.run();exit(0)
}
if let index = CommandLine.arguments.firstIndex(of:"--finish-update"), index+1 < CommandLine.arguments.count {
    exit(UpdateInstallation.finishUpdate(token:CommandLine.arguments[index+1]))
}
if CommandLine.arguments.contains("--update-check") {
    Task { @MainActor in
        do {
            if let update = try await AppUpdater.findUpdate() {
                print("Update available: \(update.tag) — \(update.releasePage.absoluteString)")
            } else { print("No newer stable Mac Duo release is available.") }
            exit(0)
        } catch { fputs("Update check failed: \(error.localizedDescription)\n",stderr);exit(1) }
    }
    dispatchMain()
}
if CommandLine.arguments.contains("--render-check") {
    do { try RenderCheck.run();exit(0) } catch { fputs("Render check failed: \(error)\n",stderr);exit(1) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

}
