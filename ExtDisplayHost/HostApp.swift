import SwiftUI
import AppKit

@main
struct ExtDisplayHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Use a non-window scene so SwiftUI never pops open a window at Mac power-on / login.
        // The main window is created and shown on demand by HostAppDelegate.
        Settings {
            EmptyView()
        }
    }
}

/// Manages the background menu-bar status item (`NSStatusItem` + `NSPopover`) and on-demand
/// main GUI window. Starts hidden in the background at power-on (no window, no Dock icon)
/// while automatically connecting USB-C displays, and shows the GUI window + Dock icon
/// only when the user explicitly opens it.
@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: HostAppDelegate?
    static var allowExplicitQuit = false
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Start hidden in the background (no Dock icon, no window on power-on).
        NSApp.setActivationPolicy(.accessory)

        let controller = HostController.shared

        let hosting = NSHostingController(
            rootView: HostMenuView(closePopover: { [weak self] in self?.popover.performClose(nil) })
                .environmentObject(controller)
        )
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 380)
        popover.contentViewController = hosting

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "ExtDisplay")
            img?.isTemplate = true
            button.image = img
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
    }

    /// Never terminate when the user closes or hides the main window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Intercept the red close (X) button to hide the window and remove from Dock while running in background.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Self.hideToBackground()
        return false
    }

    /// Only re-show the main window on Dock click if the GUI is already active in regular Dock mode.
    /// Ignore reopen events while running as a background accessory agent so Login Items / LaunchAgent
    /// at Mac power-on never pop open the GUI window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if NSApp.activationPolicy() == .regular {
            Self.showMainWindow()
        }
        return false
    }

    /// When clicking Quit on the Dock (or ⌘Q), remove the app from the Dock and hide the window
    /// while keeping ExtDisplayHost running in the background (and menu bar).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !Self.allowExplicitQuit {
            Self.hideToBackground()
            return .terminateCancel
        }
        return .terminateNow
    }

    static func hideToBackground() {
        shared?.mainWindow?.orderOut(nil)
        for window in NSApp.windows where window.title == "ExtDisplay" {
            window.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    static func showMainWindow() {
        guard let delegate = shared else { return }
        NSApp.setActivationPolicy(.regular)
        applyDockIcon()

        let window: NSWindow
        if let existing = delegate.mainWindow {
            window = existing
        } else {
            let rootView = HostMainWindowView()
                .environmentObject(HostController.shared)
            let hostingController = NSHostingController(rootView: rootView)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "ExtDisplay"
            w.contentViewController = hostingController
            w.setContentSize(NSSize(width: 760, height: 520))
            w.minSize = NSSize(width: 720, height: 480)
            w.isReleasedWhenClosed = false
            w.delegate = delegate
            w.center()
            delegate.mainWindow = w
            window = w
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func applyDockIcon() {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        } else if let iconImage = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = iconImage
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - Main Desktop GUI Window

struct HostMainWindowView: View {
    @EnvironmentObject var c: HostController

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        DevicesCard()
                        PermissionsCard()
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 16) {
                        DisplaySettingsCard()
                        StartupAndAppCard()
                    }
                    .frame(width: 320)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            c.refreshPermissions()
        }
    }
}

private struct HeaderBar: View {
    @EnvironmentObject var c: HostController

    var body: some View {
        HStack(spacing: 12) {
            ExtDisplayLogoView(size: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("ExtDisplay Host")
                    .font(.title3.bold())
                Text(c.usbStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusBadge(
                title: c.sessions.isEmpty ? "Idle" : "\(c.sessions.count) Active Display\(c.sessions.count > 1 ? "s" : "")",
                icon: c.sessions.isEmpty ? "circle.dotted" : "checkmark.circle.fill",
                color: c.sessions.isEmpty ? .secondary : .green
            )

            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple. Displays-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Display Settings", systemImage: "macwindow.on.rectangle")
            }

            Button {
                HostAppDelegate.hideToBackground()
            } label: {
                Label("Hide App", systemImage: "eye.slash")
            }
            .help("Hide window and Dock icon while continuing to run in the background")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

private struct StatusBadge: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct DevicesCard: View {
    @EnvironmentObject var c: HostController

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Devices", systemImage: "ipad.and.iphone")
                        .font(.headline)
                    Spacer()
                    if !c.sessions.isEmpty {
                        Button("Disconnect All") { c.disconnectAll() }
                            .controlSize(.small)
                    }
                }

                if c.usbDevices.isEmpty && c.sessions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "cable.connector.horizontal")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("No USB devices detected yet")
                            .font(.subheadline.weight(.medium))
                        Text("Plug in your iPad, iPhone, or Android device with a USB-C cable and open ExtDisplay on the device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }

                ForEach(c.usbDevices.values.sorted { $0.id < $1.id }) { device in
                    let session = c.session(forUSB: device.id)
                    DeviceCardRow(
                        icon: "cable.connector",
                        title: session?.deviceName ?? device.defaultTitle,
                        transport: "USB-C",
                        session: session,
                        note: session == nil ? device.lastError : nil,
                        connect: { c.setUSBAutoConnect(device.id, true) },
                        disconnect: { c.setUSBAutoConnect(device.id, false) }
                    )
                }
            }
            .padding(8)
        }
    }
}

private struct DeviceCardRow: View {
    let icon: String
    let title: String
    let transport: String
    let session: HostSession?
    let note: String?
    let connect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.subheadline.bold())
                        Text(transport)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if session != nil {
                    Button("Disconnect", action: disconnect)
                } else {
                    Button("Connect", action: connect)
                        .buttonStyle(.borderedProminent)
                }
            }

            if let session, case .streaming = session.state {
                let s = session.stats
                HStack(spacing: 12) {
                    MetricPill(label: "FPS", value: String(format: "%.0f", s.fps))
                    MetricPill(label: "Bitrate", value: String(format: "%.1f Mbps", s.mbps))
                    MetricPill(label: "RTT", value: String(format: "%.1f ms", s.rttMillis))
                    MetricPill(label: "Encode", value: String(format: "%.1f ms", s.encodeMillis))
                    MetricPill(label: "Dropped", value: "\(s.droppedFrames)")
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusText: String {
        guard let session else { return note ?? "Ready to connect" }
        switch session.state {
        case .connecting: return "Connecting…"
        case .waitingForHello: return "Handshaking…"
        case .streaming(let cfg):
            return "\(cfg.pointsWide)×\(cfg.pointsHigh) pt (\(cfg.width)×\(cfg.height) px) @ \(cfg.fps) Hz · \(cfg.codec.rawValue.uppercased())"
        case .failed(let msg): return "Error: \(msg)"
        case .closed: return "Closed"
        }
    }
}

private struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DisplaySettingsCard: View {
    @EnvironmentObject var c: HostController

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Display & Stream", systemImage: "slider.horizontal.3")
                    .font(.headline)

                Picker("Resolution", selection: $c.presetRaw) {
                    ForEach(DisplayGeometry.ScalePreset.allCases) { Text($0.title).tag($0.rawValue) }
                }

                Picker("Frame Rate", selection: $c.maxFPS) {
                    Text("60 Hz").tag(60)
                    Text("120 Hz (ProMotion)").tag(120)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Stream Quality")
                        Spacer()
                        Text("\(Int((c.quality / 0.3 * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $c.quality, in: 0.05...0.3)
                }

                Toggle("Show cursor on device", isOn: $c.showsCursor)
            }
            .padding(8)
        }
    }
}

private struct StartupAndAppCard: View {
    @EnvironmentObject var c: HostController

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Startup & Application", systemImage: "power.circle")
                    .font(.headline)

                Toggle("Auto-connect USB devices", isOn: $c.autoConnectUSB)
                Toggle("Start automatically when Mac turns on", isOn: $c.launchAtLogin)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Installed in Applications")
                            .font(.caption.weight(.medium))
                        Spacer()
                    }
                    Text(c.installedAppPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        Button("Update in /Applications") {
                            c.installToApplications()
                            if c.launchAtLogin { _ = LaunchAtLoginManager.setEnabled(true) }
                        }
                        .controlSize(.small)

                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: c.installedAppPath)])
                        }
                        .controlSize(.small)
                    }

                    Button("Open Login Items Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(8)
        }
    }
}

private struct PermissionsCard: View {
    @EnvironmentObject var c: HostController

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Permissions", systemImage: "lock.shield")
                        .font(.headline)
                    Spacer()
                    Button("Refresh") { c.refreshPermissions() }
                        .controlSize(.small)
                }

                HStack {
                    Image(systemName: c.screenRecordingGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(c.screenRecordingGranted ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text("Screen Recording").font(.subheadline.weight(.medium))
                        Text("Required to capture the virtual extended display").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !c.screenRecordingGranted {
                        Button("Grant Access") {
                            ScreenCapturer.requestPermission()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    } else {
                        Text("Granted").font(.caption).foregroundStyle(.green)
                    }
                }

                Divider()

                HStack {
                    Image(systemName: c.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(c.accessibilityGranted ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text("Accessibility").font(.subheadline.weight(.medium))
                        Text("Required for touch & Apple Pencil mouse input").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !c.accessibilityGranted {
                        Button("Grant Access") { c.requestAccessibility() }
                            .controlSize(.small)
                    } else {
                        Text("Granted").font(.caption).foregroundStyle(.green)
                    }
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Menu Bar Popover

struct HostMenuView: View {
    @EnvironmentObject var c: HostController
    var closePopover: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ExtDisplayLogoView(size: 24)
                Text("ExtDisplay").font(.headline)
                Spacer()
                Text(c.usbStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            if !c.screenRecordingGranted || !c.accessibilityGranted {
                PermissionsView()
            }

            DevicesSection()

            Divider()
            SettingsSection()
            Divider()

            HStack {
                Button("Open ExtDisplay Window") {
                    closePopover?()
                    HostAppDelegate.showMainWindow()
                }
                Spacer()
                Button("Hide App") {
                    closePopover?()
                    HostAppDelegate.hideToBackground()
                }
                Button("Quit") {
                    HostAppDelegate.allowExplicitQuit = true
                    c.disconnectAll()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { c.refreshPermissions() }
    }
}

private struct PermissionsView: View {
    @EnvironmentObject var c: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !c.screenRecordingGranted {
                Label("Screen Recording permission needed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Open Screen Recording settings") {
                    ScreenCapturer.requestPermission()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            if !c.accessibilityGranted {
                Label("Accessibility permission needed for touch input", systemImage: "hand.tap")
                    .foregroundStyle(.orange)
                Button("Grant Accessibility access") { c.requestAccessibility() }
            }
        }
        .font(.callout)
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DevicesSection: View {
    @EnvironmentObject var c: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Devices").font(.subheadline.bold())

            if c.usbDevices.isEmpty && c.sessions.isEmpty {
                Text("Connect an iPad, iPhone, or Android device with a USB-C cable and open ExtDisplay on it.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            ForEach(c.usbDevices.values.sorted { $0.id < $1.id }) { device in
                let session = c.session(forUSB: device.id)
                DeviceRow(icon: "cable.connector",
                          title: session?.deviceName ?? device.defaultTitle,
                          transport: "USB",
                          session: session,
                          note: session == nil ? device.lastError : nil,
                          connect: { c.setUSBAutoConnect(device.id, true) },
                          disconnect: { c.setUSBAutoConnect(device.id, false) })
            }
        }
    }
}

private struct DeviceRow: View {
    let icon: String
    let title: String
    let transport: String
    let session: HostSession?
    let note: String?
    let connect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).frame(width: 18)
                VStack(alignment: .leading) {
                    Text(title)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session != nil {
                    Button("Disconnect", action: disconnect)
                } else {
                    Button("Connect", action: connect)
                }
            }
            if let session, case .streaming = session.state {
                let s = session.stats
                Text(String(format: "%.0f fps · %.1f Mbps · RTT %.1f ms · enc %.1f ms · dropped %d",
                            s.fps, s.mbps, s.rttMillis, s.encodeMillis, s.droppedFrames))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        guard let session else { return note ?? "\(transport) · not connected" }
        switch session.state {
        case .connecting: return "\(transport) · connecting…"
        case .waitingForHello: return "\(transport) · handshaking…"
        case .streaming(let cfg):
            return "\(transport) · \(cfg.pointsWide)×\(cfg.pointsHigh) pt @ \(cfg.fps) Hz · \(cfg.codec.rawValue.uppercased())"
        case .failed(let msg): return "\(transport) · error: \(msg)"
        case .closed: return "\(transport) · closed"
        }
    }
}

private struct SettingsSection: View {
    @EnvironmentObject var c: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display").font(.subheadline.bold())
            Picker("Resolution", selection: $c.presetRaw) {
                ForEach(DisplayGeometry.ScalePreset.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Frame rate", selection: $c.maxFPS) {
                Text("60 Hz").tag(60)
                Text("120 Hz (ProMotion)").tag(120)
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Quality")
                Slider(value: $c.quality, in: 0.05...0.3)
            }
            Toggle("Show cursor on device", isOn: $c.showsCursor)
            Toggle("Auto-connect USB devices", isOn: $c.autoConnectUSB)
            Toggle("Start automatically when Mac turns on", isOn: $c.launchAtLogin)
        }
    }
}
