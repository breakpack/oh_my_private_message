import AppKit
import Carbon
import SwiftUI

@main struct PrivateCatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private let model = MessengerModel.shared
    private var statusItem: NSStatusItem!
    private var catPanel: NSPanel!
    private var chatWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var composerWindow: ComposerPanel?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        makeMenuBarItem()
        makeCatPanel()
        let keyCode = UserDefaults.standard.integer(forKey: "hotkeyCode")
        registerHotKey(keyCode: UInt32(keyCode == 0 ? 46 : keyCode))
        model.persistSettings()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showChat() {
        if chatWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "PrivateCat"
            window.contentView = NSHostingView(rootView: ChatView(model: model))
            window.isReleasedWhenClosed = false
            chatWindow = window
        }
        chatWindow?.center()
        chatWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "PrivateCat 설정"
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showComposer() {
        if composerWindow == nil {
            let panel = ComposerPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 64),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: ComposerView(model: model))
            panel.isReleasedWhenClosed = false
            composerWindow = panel
        }
        guard let frame = NSScreen.main?.visibleFrame, let composerWindow else { return }
        composerWindow.setFrameOrigin(NSPoint(x: frame.midX - composerWindow.frame.width / 2, y: frame.minY + 36))
        composerWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideComposer() { composerWindow?.orderOut(nil) }

    func resizeCatPanel(for bubbleCount: Int) {
        guard let catPanel else { return }
        let frame = catPanel.frame
        let width: CGFloat = bubbleCount == 0 ? 112 : 260
        let height: CGFloat = 112 + CGFloat(min(bubbleCount, 4)) * 60
        catPanel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - height,
                                 width: width, height: height), display: true)
    }

    func registerHotKey(keyCode: UInt32) {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard hotKeyHandler == nil else {
            let identifier = EventHotKeyID(signature: OSType(0x50434154), id: 1)
            RegisterEventHotKey(keyCode, UInt32(optionKey | shiftKey), identifier,
                                GetApplicationEventTarget(), 0, &hotKey)
            return
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), privateCatHotKeyCallback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        let identifier = EventHotKeyID(signature: OSType(0x50434154), id: 1)
        RegisterEventHotKey(keyCode, UInt32(optionKey | shiftKey), identifier,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    private func makeMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "🐱"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "대화 열기", action: #selector(openChat), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func makeCatPanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 112, height: 112),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: CatView(model: model))
        panel.setFrameOrigin(NSPoint(x: (NSScreen.main?.visibleFrame.maxX ?? 600) - 140, y: 100))
        panel.orderFrontRegardless()
        catPanel = panel
    }

    @objc private func openChat() { showChat() }
    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

private let privateCatHotKeyCallback: EventHandlerProcPtr = { _, event, userData in
    guard let event, let userData else { return noErr }
    var identifier = EventHotKeyID()
    let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    if result == noErr, identifier.signature == OSType(0x50434154), identifier.id == 1 {
        let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in delegate.showComposer() }
    }
    return noErr
}

private final class ComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
