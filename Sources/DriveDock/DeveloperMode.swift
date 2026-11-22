import AppKit
import ScreenCaptureKit
import SwiftUI

/// Developer tools behind launch arguments – never used in normal operation. None of them
/// mounts, touches the keychain or changes Finder, so they can run next to a normal DriveDock.
///
///     --demo [--show servers|general|menu] [--appearance light|dark] [--capture <file.png>]
///         The real app with made-up servers, for trying the UI. With --capture it saves the
///         window (with shadow, as the window server draws it) and quits – see
///         scripts/make-screenshots.sh. Capturing needs the screen recording permission.
///     --render-banner <dir>
///         README banner (banner.jpg, Retina) and GitHub social preview (social-preview.jpg,
///         1280 × 640) from the dark screenshots in <dir>.
///     --ui-stress
///         Opens and closes window and menu many times and reports memory (nothing may stay alive).
enum DeveloperMode {
    /// Runs the requested tool and returns true, or returns false for a normal start.
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        let tool: (@MainActor () -> Void)?
        if arguments.contains("--demo") {
            tool = startDemo
        } else if let directory = value(after: "--render-banner") {
            tool = { renderBanner(in: URL(fileURLWithPath: directory, isDirectory: true)) }
        } else if arguments.contains("--ui-stress") {
            tool = startStressTest
        } else {
            tool = nil
        }
        guard let tool else { return false }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            if let appearance = value(after: "--appearance") {
                app.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            }
            app.finishLaunching()
            // Inside the regular event loop, like the real app: window teardown and SwiftUI
            // updates only run there.
            DispatchQueue.main.async { MainActor.assumeIsolated { tool() } }
            app.run()
        }
        return true
    }

    private static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    // MARK: - Demo

    @MainActor private static var demo: (ServerWindowController, MenuBarController, NSWindow?)?

    @MainActor
    private static func startDemo() {
        let manager = Demo.manager()
        let window = ServerWindowController(manager: manager)
        window.autosavesFrame = false
        let show = value(after: "--show") ?? "servers"
        window.startOnGeneral = show == "general"
        let menuBar = MenuBarController(manager: manager) { window.show() }
        LoginItem.demoValue = true
        NSApp.mainMenu = MainMenu.make()
        let capturing = value(after: "--capture")
        if capturing != nil {
            menuBar.keepPopoverOpen()
        }
        NSApp.activate()
        var anchor: NSWindow?
        if show == "menu" {
            // The demo's status item may well end up hidden behind the notch or other items;
            // the popover hangs from an invisible spot below the menu bar instead.
            let spot = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 22, height: 2),
                                styleMask: .borderless, backing: .buffered, defer: false)
            spot.isOpaque = false
            spot.backgroundColor = .clear
            spot.ignoresMouseEvents = true
            if let screen = NSScreen.main {
                spot.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX + 200, y: screen.visibleFrame.maxY - 6))
            }
            spot.orderFrontRegardless()
            anchor = spot
            DispatchQueue.main.async {
                MainActor.assumeIsolated { menuBar.showPopover(relativeTo: spot.contentView!) }
            }
        } else {
            window.show()
            if let offset = value(after: "--scroll").flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MainActor.assumeIsolated { scrollDetail(of: window, to: offset) }
                }
            }
        }
        demo = (window, menuBar, anchor)
        guard let file = capturing else { return }
        Task { @MainActor in
            // Time for SwiftUI to lay out and load the symbols; then wait (a few seconds at most)
            // until the app is active – make-screenshots.sh brings it to the front.
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<50 where !NSApp.isActive {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(800))
            do {
                let url = URL(fileURLWithPath: file)
                if show == "menu" {
                    // Liquid Glass shows what lies behind it – captured on its own, that's black.
                    // A neutral backdrop like a desktop makes it look as it does in real use.
                    guard let number = menuBar.popoverWindowNumber,
                          let popover = NSApp.window(withWindowNumber: number) else {
                        throw CaptureError(message: "The menu didn't open")
                    }
                    let backdrop = makeBackdrop(behind: popover)
                    try? await Task.sleep(for: .milliseconds(600))
                    try await captureArea(of: backdrop.windowNumber, to: url, cornerRadius: 26)
                    backdrop.close()
                } else {
                    try await capture(windowNumber: window.windowNumber ?? -1, to: url)
                }
                print("Saved \(file)\(NSApp.isActive ? "" : " (app wasn't active – window may look inactive)")")
            } catch {
                print("Capture failed: \(error.localizedDescription)")
            }
            exit(0)
        }
    }

    /// Scrolls the tallest scroll view (the server page) to `offset` points from its top.
    @MainActor
    private static func scrollDetail(of controller: ServerWindowController, to offset: Double) {
        guard let number = controller.windowNumber,
              let root = NSApp.window(withWindowNumber: number)?.contentView else { return }
        var scrollViews: [NSScrollView] = []
        func collect(_ view: NSView) {
            if let scroll = view as? NSScrollView { scrollViews.append(scroll) }
            view.subviews.forEach(collect)
        }
        collect(root)
        guard let scroll = scrollViews.max(by: {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        }), let document = scroll.documentView else { return }
        let maxOffset = max(0, document.frame.height - scroll.contentView.bounds.height)
        let y = min(offset, maxOffset)
        let top = document.isFlipped ? y : maxOffset - y
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: top - scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func requireCapturePermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw CaptureError(message: "DriveDock needs the screen recording permission for screenshots: "
                + "System Settings → Privacy & Security → Screen & System Audio Recording. "
                + "Switch it on, then run this again (and off afterwards, if you like).")
        }
    }

    /// The window as the window server draws it (Liquid Glass and shadow included), on a
    /// transparent background.
    private static func capture(windowNumber: Int, to url: URL) async throws {
        try requireCapturePermission()
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { Int($0.windowID) == windowNumber }) else {
            throw CaptureError(message: "Window \(windowNumber) not found")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = false
        configuration.shouldBeOpaque = false
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try write(image, to: url)
    }

    /// Everything of DriveDock inside the given window's frame, as a card with rounded corners.
    private static func captureArea(of windowNumber: Int, to url: URL, cornerRadius: CGFloat) async throws {
        try requireCapturePermission()
        let content = try await SCShareableContent.currentProcess
        guard let area = content.windows.first(where: { Int($0.windowID) == windowNumber }),
              let display = content.displays.first(where: { $0.frame.intersects(area.frame) }) else {
            throw CaptureError(message: "Window \(windowNumber) not found")
        }
        let filter = SCContentFilter(display: display, including: content.windows)
        let scale = CGFloat(filter.pointPixelScale)
        let rect = area.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.sourceRect = rect
        configuration.width = Int(rect.width * scale)
        configuration.height = Int(rect.height * scale)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: cornerRadius * scale, cornerHeight: cornerRadius * scale, transform: nil))
        context.clip()
        context.draw(image, in: bounds)
        guard let card = context.makeImage() else { return }
        try write(card, to: url)
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A calm, desktop-like background around and behind `window`.
    @MainActor
    private static func makeBackdrop(behind window: NSWindow) -> NSWindow {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let colors = dark
            ? [Color(red: 0.16, green: 0.18, blue: 0.24), Color(red: 0.09, green: 0.10, blue: 0.14)]
            : [Color(red: 0.93, green: 0.95, blue: 0.98), Color(red: 0.84, green: 0.88, blue: 0.94)]
        // The popover window has empty room below the menu; even margins all around.
        let f = window.frame
        let area = NSRect(x: f.minX - 36, y: f.minY + 13, width: f.width + 72, height: f.height + 56)
        let backdrop = NSWindow(contentRect: area, styleMask: .borderless,
                                backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.contentView = NSHostingView(rootView: LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
        backdrop.level = window.level
        backdrop.order(.below, relativeTo: window.windowNumber)
        return backdrop
    }

    // MARK: - Banner

    /// Combines the real dark screenshots into the README banner (also the social preview).
    @MainActor
    private static func renderBanner(in directory: URL) {
        defer { exit(0) }
        guard let menu = NSImage(contentsOf: directory.appendingPathComponent("menu-dark.png")),
              let servers = NSImage(contentsOf: directory.appendingPathComponent("servers-dark.png")),
              let icon = NSApp.applicationIconImage else {
            print("menu-dark.png and servers-dark.png are needed in \(directory.path)")
            return
        }
        // JPEG in 8-bit sRGB: ImageRenderer works in 16 bit, which made a 9 MB PNG. GitHub's
        // social preview must stay under 1 MB; the README gets the sharp Retina version.
        for (name, scale) in [("banner.jpg", 2.0), ("social-preview.jpg", 1.0)] {
            let renderer = ImageRenderer(content: Banner(icon: icon, menu: menu, servers: servers))
            renderer.scale = scale
            guard let image = renderer.cgImage,
                  let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { continue }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flat = context.makeImage() else { continue }
            let url = directory.appendingPathComponent(name)
            try? NSBitmapImageRep(cgImage: flat).representation(using: .jpeg, properties: [.compressionFactor: 0.88])?.write(to: url)
            print("Rendered \(url.path)")
        }
    }

    // MARK: - UI stress test

    /// Opens and closes the server window and the menu many times, one step per timer tick
    /// (like real clicks: the normal event loop runs between the steps), then sends status
    /// changes while everything is closed, and reports memory and surviving windows.
    @MainActor
    private static func startStressTest() {
        let manager = Demo.manager()
        let windows = ServerWindowController(manager: manager)
        windows.offscreen = true
        let menuBar = MenuBarController(manager: manager) {}
        let baseWindows = NSApp.windows.count
        let start = footprintMB()

        var steps: [() -> Void] = []
        // Each cycle also puts the cursor into the user and password fields, like typing a login
        // would – the fields AppKit's AutoFill attaches its suggestion window to.
        for _ in 0..<20 {
            steps += [{ windows.show() }, { focusLoginFields() }, { windows.close() }]
        }
        steps.append {
            print(String(format: "after 20 window cycles: %.1f MB, windows alive: %d (before: %d)",
                         footprintMB(), NSApp.windows.count, baseWindows))
        }
        for _ in 0..<20 { steps += [{ menuBar.togglePopover(nil) }, { menuBar.togglePopover(nil) }] }
        steps.append {
            print(String(format: "after 20 menu cycles: %.1f MB, windows alive: %d", footprintMB(), NSApp.windows.count))
        }
        for _ in 0..<30 { steps.append { for _ in 0..<10 { manager.objectWillChange.send() } } }
        steps.append {
            print(String(format: "UI stress: start %.1f MB · end %.1f MB · window open: %@ · menu open: %@",
                         start, footprintMB(), windows.isOpen ? "yes" : "no", menuBar.isPopoverShown ? "yes" : "no"))
            print("READY – process stays alive 20 s for heap inspection")
            fflush(stdout)
        }
        var index = 0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard index < steps.count else {
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(0) }
                    return
                }
                steps[index]()
                index += 1
                fflush(stdout)
            }
        }
    }

    @MainActor
    private static func focusLoginFields() {
        guard let window = NSApp.windows.first(where: { $0.contentViewController != nil && $0.title.hasPrefix("Fileserver") }),
              let root = window.contentView else { return }
        var fields: [NSTextField] = []
        func collect(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable { fields.append(field) }
            view.subviews.forEach(collect)
        }
        collect(root)
        // User and password are the last two editable fields above the share search.
        for field in fields where field is NSSecureTextField || field.placeholderString == tr("User name") {
            window.makeFirstResponder(field)
        }
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

private struct CaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Demo data

private enum Demo {
    @MainActor
    static func manager() -> ConnectionManager {
        var anna = Connection(name: "Fileserver (Anna)", host: "fileserver.example.com", shares: [], username: "anna")
        anna.domain = "CORP"
        anna.mountAllShares = true
        anna.color = .blue

        var admin = Connection(name: "Fileserver (Admin)", host: "fileserver.example.com",
                               shares: ["IT", "Backup", "Software", "C$"], username: "admin")
        admin.domain = "CORP"
        admin.color = .orange

        var nas = Connection(name: "NAS (Home)", host: "nas.local", shares: ["Photos", "Music", "Time Machine"], username: "anna")
        nas.alternateHosts = ["100.64.0.12"]
        nas.color = .green

        var cloud = Connection(name: "Nextcloud", kind: .webdavs, host: "cloud.example.com",
                               shares: ["remote.php/dav/files/anna"], username: "anna")
        cloud.color = .purple

        let offered: [ShareBrowser.Share] = [
            .init(name: "Archive", comment: "Closed projects"),
            .init(name: "Design", comment: ""),
            .init(name: "Finance", comment: "Accounting"),
            .init(name: "HR", comment: "Human resources"),
            .init(name: "Marketing", comment: ""),
            .init(name: "Projects", comment: "Running projects"),
            .init(name: "Public", comment: "Everyone"),
            .init(name: "Sales", comment: ""),
            .init(name: "Software", comment: "Installers and licenses"),
            .init(name: "Templates", comment: ""),
            .init(name: "Training", comment: ""),
            .init(name: "ADMIN$", comment: "Remote Admin"),
            .init(name: "C$", comment: "Default share"),
        ]
        let annaDenied: Set<String> = ["Finance", "HR"]
        let annaMounted = offered.map(\.name).filter { !$0.hasSuffix("$") && !annaDenied.contains($0) }

        return ConnectionManager(
            demo: [anna, admin, nas, cloud],
            status: [
                anna.id: .connected,
                admin.id: .connected,
                nas.id: .partial(mounted: 2, total: 3, detail: "Time Machine: " + tr("Server not reachable")),
                cloud.id: .connecting,
            ],
            discovered: [anna.id: offered],
            denied: [anna.id: annaDenied],
            mountedShares: [
                anna.id: annaMounted,
                admin.id: ["IT", "Backup", "Software", "C$"],
                nas.id: ["Photos", "Music"],
            ])
    }
}

// MARK: - Banner

/// README banner and GitHub social preview (1280 × 640), made from real screenshots.
private struct Banner: View {
    let icon: NSImage
    let menu: NSImage
    let servers: NSImage

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.04, green: 0.10, blue: 0.30), Color(red: 0.09, green: 0.33, blue: 0.80)],
                           startPoint: .bottomLeading, endPoint: .topTrailing)
            RadialGradient(colors: [.white.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 760)

            // The screenshots, partly running off the right edge.
            Image(nsImage: servers)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 700)
                .offset(x: 700, y: 130)
            Image(nsImage: menu)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 500)
                // Popover shadows are separate windows and not in the capture.
                .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                .offset(x: 560, y: 80)

            VStack(alignment: .leading, spacing: 18) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                Text(verbatim: "DriveDock")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                Text(verbatim: "Your network drives,\nalways in Finder.")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                VStack(alignment: .leading, spacing: 10) {
                    feature("arrow.triangle.2.circlepath", "Reconnects after sleep, Wi-Fi and VPN changes")
                    feature("person.2.fill", "Several users on the same server")
                    feature("externaldrive.connected.to.line.below.fill", "SMB & WebDAV · free and open source")
                }
                .padding(.top, 8)
            }
            .foregroundStyle(.white)
            .padding(.leading, 72)
            .padding(.top, 70)
        }
        .frame(width: 1280, height: 640)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: symbol).frame(width: 26)
        }
        .font(.system(size: 19, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
    }
}
