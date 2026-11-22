import AppKit
import Combine
import SwiftUI

/// Entry point with a plain AppKit lifecycle instead of SwiftUI scenes.
///
/// SwiftUI's `Window` and `MenuBarExtra` only hide their content when closed: the hidden
/// views kept re-rendering on every status change and their view state piled up over days
/// (150 MB after nine days of uptime). Here the server window and the menu popover are built
/// when they open and released when they close, so nothing renders in the background.
@main
enum DriveDockMain {
    static func main() {
        if DeveloperMode.runIfRequested() { return }
        // Login item and a manual start can race; keep the instance that came first.
        // (Opening the app again while it runs reaches the running instance as a "reopen".)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current && !isExiting($0.processIdentifier) }
        if !others.isEmpty {
            others.first?.activate()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

/// A quit instance can hang in the kernel for a while (e.g. while a share is unmounted) and
/// still be listed as running. It must not keep the new instance from starting.
private func isExiting(_ pid: pid_t) -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return true }
    return info.kp_proc.p_stat == SZOMB || (info.kp_proc.p_flag & P_WEXIT) != 0
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var manager: ConnectionManager?
    private var menuBar: MenuBarController?
    private var serverWindow: ServerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        LoginItem.enableOnFirstLaunch()
        let manager = ConnectionManager()
        let serverWindow = ServerWindowController(manager: manager)
        self.manager = manager
        self.serverWindow = serverWindow
        menuBar = MenuBarController(manager: manager) { serverWindow.show() }
    }

    /// Opening DriveDock again (Finder, Spotlight, Dock) while it runs shows the server window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        serverWindow?.show()
        return false
    }
}

/// The status item and its popover. The popover's SwiftUI content only exists while it is shown.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let manager: ConnectionManager
    private let openServers: () -> Void
    private var changes: AnyCancellable?
    private var symbol = ""

    init(manager: ConnectionManager, openServers: @escaping () -> Void) {
        self.manager = manager
        self.openServers = openServers
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.setAccessibilityLabel("DriveDock")
        updateIcon()
        // objectWillChange fires before the value changes; read it on the next run loop turn.
        changes = manager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
    }

    private func updateIcon() {
        let new = manager.menuBarSymbol
        guard new != symbol else { return }
        symbol = new
        let image = NSImage(systemSymbolName: new, accessibilityDescription: "DriveDock")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    var isPopoverShown: Bool { popover.isShown }
    var popoverWindowNumber: Int? { popover.contentViewController?.view.window?.windowNumber }

    /// Demo: the popover stays open although the demo app isn't the active one.
    func keepPopoverOpen() {
        popover.behavior = .applicationDefined
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem.button else { return }
        showPopover(relativeTo: button)
    }

    func showPopover(relativeTo anchor: NSView) {
        let content = MenuView { [weak self] in
            self?.popover.performClose(nil)
            self?.openServers()
        }
        let host = NSHostingController(rootView: content.environmentObject(manager))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        host.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        // Release the SwiftUI content; a hidden view would keep re-rendering on every change.
        popover.contentViewController = nil
    }
}

/// The server window. Built on demand and released completely when closed.
@MainActor
final class ServerWindowController: NSObject, NSWindowDelegate {
    private let manager: ConnectionManager
    private var window: NSWindow?
    /// Stress test: build the window invisibly.
    var offscreen = false
    /// Demo mode: don't overwrite the real window position.
    var autosavesFrame = true
    var startOnGeneral = false

    init(manager: ConnectionManager) {
        self.manager = manager
    }

    var isOpen: Bool { window != nil }
    var windowNumber: Int? { window?.windowNumber }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = Self.makeWindow(SettingsView(startOnGeneral: startOnGeneral).environmentObject(manager))
        window.delegate = self
        self.window = window
        if offscreen {
            // Invisible but on screen and key – like a real window, without flashing up.
            window.alphaValue = 0
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.center()
            if autosavesFrame { window.setFrameAutosaveName("DriveDockServers") }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func close() {
        window?.close()
    }

    static func makeWindow(_ content: some View) -> NSWindow {
        let host = NSHostingController(rootView: content)
        host.sizingOptions = .minSize
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentViewController = host
        // Without this, AppKit makes the first text field (the server name) first responder as
        // soon as the window appears – selected text, and AppKit's AutoFill attaching its
        // suggestion window to it. SwiftUI's default focus (the server list) applies instead.
        window.initialFirstResponder = host.view
        window.title = "DriveDock"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 640))
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the whole SwiftUI view tree; the next show() builds a fresh one. End text editing
        // first, so no text input or AutoFill session still points at a field in it.
        let closing = window
        closing?.makeFirstResponder(nil)
        window = nil
        DispatchQueue.main.async {
            closing?.contentViewController = nil
            closing?.delegate = nil
        }
    }
}

/// Invisible for a menu bar app, but its key equivalents make ⌘C/⌘V/⌘A, ⌘Z, ⌘W and ⌘Q work.
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Quit DriveDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(window))
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}

enum AppInfo {
    static let repositoryURL = URL(string: "https://github.com/its-sven/DriveDock")!
}
