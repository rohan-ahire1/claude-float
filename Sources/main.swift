// Claude Float: a small always-on-top dot that shows what your Claude chats are doing.
// Click it to answer prompts, read and reply to today's chats, or start a new one.
// Claude Code hooks (hook.sh) post every event to the local server in Hooks.swift.

import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    lazy var chats = ChatsModel(store: store)
    let nav = Nav()
    var server: HookServer!
    var dot: NSPanel!
    var dotView: DotView!
    var panel: KeyPanel!
    var contentHeight: CGFloat = 120
    var lastHide = Date.distantPast
    var keepOpen = false
    var watchers: [AnyCancellable] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)  // writing to a chat that just exited must not kill the app
        DispatchQueue.global(qos: .utility).async { _ = loginPath }
        installEditMenu()
        makeDot()
        makePanel()
        do {
            server = try HookServer(token: loadToken(), store: store)
            server.start { [weak self] error in self?.fail("Claude Float couldn't start its local server (\(error)). Is it already running?") }
        } catch {
            fail("Claude Float couldn't start: \(error)")
        }
        store.onAllAnswered = { [weak self] in
            if self?.nav.route == .home { self?.hidePanel() }
        }
        chats.chooseFolder = { [weak self] in self?.pickFolder() }
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshDot() }
            .store(in: &watchers)
        nav.$route
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in if self?.panel.isVisible == true { self?.placePanel() } }
            .store(in: &watchers)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.store.appActivated(app?.bundleIdentifier)
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.store.prune() }
        refreshDot()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.handBackAll()
        chats.stopAll()
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func loadToken() -> String {
        try? FileManager.default.createDirectory(at: floatDir, withIntermediateDirectories: true)
        let url = floatDir.appendingPathComponent("token")
        if let saved = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        try? token.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    /// Accessory apps have no visible menu bar, but this keeps copy and paste working in text fields.
    private func installEditMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = edit
        main.addItem(item)
        NSApp.mainMenu = main
    }

    private func floating(_ p: NSPanel) {
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
    }

    private func makeDot() {
        let size: CGFloat = 48
        dot = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        floating(dot)
        dot.hasShadow = false
        dotView = DotView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        dotView.onClick = { [weak self] in self?.togglePanel() }
        dotView.onMoved = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(NSStringFromPoint(self.dot.frame.origin), forKey: "dotOrigin")
            if self.panel.isVisible { self.placePanel() }
        }
        dotView.onRightClick = { [weak self] event in self?.showMenu(event) }
        dot.contentView = dotView

        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var origin = NSPoint(x: vf.maxX - size - 16, y: vf.maxY - size - 16)
        if let saved = UserDefaults.standard.string(forKey: "dotOrigin") {
            let p = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: 10, dy: 10).contains(NSPoint(x: p.x + size / 2, y: p.y + size / 2)) }) {
                origin = p
            }
        }
        dot.setFrameOrigin(origin)
        dot.orderFrontRegardless()
    }

    private func makePanel() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        floating(panel)
        panel.hasShadow = true
        panel.onEscape = { [weak self] in self?.hidePanel() }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: PanelRoot(store: store, chats: chats, nav: nav) { [weak self] height in
            guard let self else { return }
            self.contentHeight = height
            if self.panel.isVisible && self.nav.route == .home { self.placePanel() }
        })
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, !self.keepOpen else { return }
            self.hidePanel()
        }
    }

    private func togglePanel() {
        if panel.isVisible { hidePanel(); return }
        // A click on the dot first takes focus from the panel; don't reopen what that click just closed.
        if Date().timeIntervalSince(lastHide) < 0.3 { return }
        showPanel()
    }

    private func showPanel() {
        store.markSeen()
        chats.setActive(true)
        placePanel()
        panel.makeKeyAndOrderFront(nil)
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        lastHide = Date()
        panel.orderOut(nil)
        chats.setActive(false)
    }

    private func pickFolder() -> String? {
        keepOpen = true
        defer {
            keepOpen = false
            showPanel()
        }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.prompt = "Use folder"
        NSApp.activate(ignoringOtherApps: true)
        return picker.runModal() == .OK ? picker.url?.path : nil
    }

    private func placePanel() {
        let d = dot.frame
        let vf = dot.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let w: CGFloat = nav.route == .home ? 380 : 460
        let wanted = nav.route == .home ? max(contentHeight, 80) : 640
        let h = min(wanted, min(nav.route == .home ? 600 : 680, vf.height - 40))
        var x = d.midX > vf.midX ? d.maxX - 8 - w : d.minX + 8
        var y = d.midY > vf.midY ? d.minY - h + 4 : d.maxY - 4
        x = min(max(x, vf.minX + 8), vf.maxX - w - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - h - 8)
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    private func refreshDot() {
        let count = store.needsCount
        let help: String
        if count > 0 {
            dotView.show(color: .systemOrange, alpha: 1, count: count, beat: 1.1)
            help = count == 1 ? "1 chat needs you" : "\(count) chats need you"
        } else if store.anyUnseenDone {
            dotView.show(color: .systemGreen, alpha: 1, count: 0, beat: 0)
            help = "Finished"
        } else if store.anyWorking {
            dotView.show(color: .systemBlue, alpha: 1, count: 0, beat: 2.2)
            help = "Working…"
        } else {
            dotView.show(color: .systemGray, alpha: 0.75, count: 0, beat: 0)
            help = "Nothing running"
        }
        dotView.toolTip = "Claude Float: \(help)"
    }

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        let newChat = NSMenuItem(title: "New chat…", action: #selector(newChat), keyEquivalent: "")
        newChat.target = self
        menu.addItem(newChat)
        let hold = NSMenuItem(title: "Ask here even when Claude is in front", action: #selector(toggleHold), keyEquivalent: "")
        hold.target = self
        hold.state = store.holdAlways ? .on : .off
        menu.addItem(hold)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Float", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: dotView)
    }

    @objc private func newChat() {
        nav.route = .newChat
        showPanel()
    }

    @objc private func toggleHold() { store.holdAlways.toggle() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
