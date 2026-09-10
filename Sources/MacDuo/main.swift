import AppKit
import SwiftUI
import FoldCore
import OSLog

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    var model: AppModel!
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var screenObserver: NSObjectProtocol?
    private let logger = Logger(subsystem:"local.lidflow.mac",category:"settings")
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        let content = NSHostingView(rootView:Controls(model:model))
        // The window owns its size. SwiftUI's ideal content height must never
        // stretch it to the screen edges; every control stays visible beside the preview.
        content.sizingOptions = []
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:940,height:528),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.delegate = self
        window.title = "Mac Duo"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = content
        window.collectionBehavior = [.fullScreenNone]
        window.isReleasedWhenClosed = false
        fitSettingsWindow(center:true)
        screenObserver = NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitSettingsWindow() }
        }
        model.showWindow = { [weak self] in self?.showSettings() }
        model.refreshLaunchAtLoginStatus()
        model.overlayVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            self.updateSettingsLevel()
            if visible {
                self.logger.notice("Effect shown; settings level: \(self.window.level.rawValue); app active: \(NSApp.isActive,privacy:.public); settings on current desktop: \(self.window.isOnActiveSpace,privacy:.public).")
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        statusItem.button?.image = AppBrand.menuBarMark
        statusItem.button?.toolTip = "Mac Duo — your desktop follows your lid"
        let menu = NSMenu();menu.delegate = self;statusItem.menu = menu
        let appMenu = NSMenu()
        let appItem = NSMenuItem();appMenu.addItem(appItem)
        let submenu = NSMenu();submenu.addItem(effectItem());submenu.addItem(appearanceItem());submenu.addItem(.separator())
        submenu.addItem(withTitle:"Quit Mac Duo",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu = submenu;NSApp.mainMenu = appMenu
        // Login items are accessory apps and should remain in the menu bar. A
        // manually opened app remains discoverable through its Settings window.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in
            guard let self else { return }
            if !self.model.launchAtLogin || NSApp.isActive { self.showSettings() }
        }
        if let index = CommandLine.arguments.firstIndex(of:"--overlay-check"), index+1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index+1]
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self] in self?.model.checkOverlay(output:path) }
        }
        if CommandLine.arguments.contains("--enable") {
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self] in self?.model.enable() }
        }
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
    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshLaunchAtLoginStatus()
        updateSettingsLevel()
    }
    func applicationDidResignActive(_ notification: Notification) { window?.level = .normal }
    func windowDidBecomeKey(_ notification: Notification) { updateSettingsLevel() }
    func windowDidResignKey(_ notification: Notification) { window?.level = .normal }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window.occlusionState.contains(.visible) { model.wakePreview() }
        else { model.previewView?.isPaused = true }
    }
    func windowWillClose(_ notification:Notification) { model.previewView?.isPaused = true }
    @objc func toggleEffect() { if model.enabled { model.pause() } else { model.enable() } }
    @objc func toggleLaunchAtLogin() { model.launchAtLogin.toggle() }
    @objc func testEffect() { model.testDesktop() }
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
        let item = NSMenuItem(title:"Effect",action:nil,keyEquivalent:"")
        item.image = NSImage(systemSymbolName:model.effect.symbol,accessibilityDescription:nil)
        let menu = NSMenu(title:"Effect");menu.identifier = NSUserInterfaceItemIdentifier("effect");menu.delegate = self
        for effect in FoldEffect.allCases {
            let option = menu.addItem(withTitle:effect.title,action:#selector(setEffect(_:)),keyEquivalent:"")
            option.target = self;option.representedObject = effect.persistedIdentifier
            option.toolTip = effect.summary
            option.state = model.effect == effect ? .on : .off
        }
        item.submenu = menu
        return item
    }
    private func appearanceItem() -> NSMenuItem {
        let item = NSMenuItem(title:"Appearance",action:nil,keyEquivalent:"")
        item.image = NSImage(systemSymbolName:"circle.lefthalf.filled",accessibilityDescription:nil)
        let menu = NSMenu(title:"Appearance");menu.identifier = NSUserInterfaceItemIdentifier("appearance");menu.delegate = self
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
        model.refreshLaunchAtLoginStatus()
        menu.removeAllItems()
        let state = NSMenuItem(title:model.lidAngle.map{String(format:"Lid angle: %.0f°",$0)} ?? "Sensor unavailable",action:nil,keyEquivalent:"")
        state.isEnabled = false;menu.addItem(state)
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle:model.enabled ? "Pause Mac Duo" : "Enable Mac Duo",action:#selector(toggleEffect),keyEquivalent:"");toggle.target = self
        let settings = menu.addItem(withTitle:"Open Mac Duo…",action:#selector(showSettings),keyEquivalent:",");settings.target = self
        let test = menu.addItem(withTitle:"Test desktop for 8 seconds",action:#selector(testEffect),keyEquivalent:"");test.target = self
        menu.addItem(effectItem())
        menu.addItem(appearanceItem())
        let login = menu.addItem(withTitle:"Launch at Login",action:#selector(toggleLaunchAtLogin),keyEquivalent:"")
        login.target = self
        login.state = model.launchAtLogin ? .on : .off
        login.toolTip = model.launchAtLoginStatusText
        if model.launchAtLoginStatus == .requiresApproval {
            login.title = "Launch at Login (Approval Needed)"
        }
        if model.launchAtLoginStatus == .requiresApproval {
            let approval = menu.addItem(withTitle:"Open Login Items Settings…",action:#selector(openLoginItems),keyEquivalent:"")
            approval.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle:"Quit Mac Duo",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    }
    @objc private func openLoginItems() { model.openLoginItems() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool { showSettings();return true }
    func applicationWillTerminate(_ notification:Notification) {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        model.shutdown()
    }
}

MainActor.assumeIsolated {
if CommandLine.arguments.contains("--render-check") {
    do { try RenderCheck.run();exit(0) } catch { fputs("Render check failed: \(error)\n",stderr);exit(1) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

}
