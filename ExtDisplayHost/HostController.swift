import Foundation
import SwiftUI
import Combine

/// App-level state: USB device discovery, sessions and settings.
@MainActor
final class HostController: ObservableObject {
    static let shared = HostController()

    struct USBDevice: Identifiable, Equatable {
        let id: Int          // usbmuxd DeviceID
        let serial: String
        var autoConnect = true
        var lastError: String?
    }

    @Published private(set) var usbDevices: [Int: USBDevice] = [:]
    @Published private(set) var sessions: [HostSession] = []
    @Published private(set) var usbStatus: String = "Starting…"
    @Published var screenRecordingGranted = ScreenCapturer.hasPermission()
    @Published var accessibilityGranted = InputInjector.isTrusted(prompt: false)
    @Published var installedAppPath: String = LaunchAtLoginManager.isInstalledInApplications
        ? LaunchAtLoginManager.applicationsAppURL.path : Bundle.main.bundleURL.path

    @Published var presetRaw: String = HostController.defaults.string(forKey: "preset") ?? DisplayGeometry.ScalePreset.retina.rawValue {
        didSet { Self.defaults.set(presetRaw, forKey: "preset"); pushSettings() }
    }
    @Published var maxFPS: Int = HostController.defaults.object(forKey: "maxFPS") as? Int ?? 60 {
        didSet { Self.defaults.set(maxFPS, forKey: "maxFPS"); pushSettings() }
    }
    @Published var quality: Double = HostController.defaults.object(forKey: "quality") as? Double ?? 0.12 {
        didSet { Self.defaults.set(quality, forKey: "quality"); pushSettings() }
    }
    @Published var showsCursor: Bool = HostController.defaults.object(forKey: "showsCursor") as? Bool ?? true {
        didSet { Self.defaults.set(showsCursor, forKey: "showsCursor"); pushSettings() }
    }
    @Published var autoConnectUSB: Bool = HostController.defaults.object(forKey: "autoConnectUSB") as? Bool ?? true {
        didSet { Self.defaults.set(autoConnectUSB, forKey: "autoConnectUSB") }
    }
    @Published var launchAtLogin: Bool = HostController.defaults.object(forKey: "launchAtLogin") as? Bool ?? true {
        didSet {
            Self.defaults.set(launchAtLogin, forKey: "launchAtLogin")
            _ = LaunchAtLoginManager.setEnabled(launchAtLogin)
        }
    }

    private static let defaults = UserDefaults.standard

    private let usb = USBMuxClient()
    private var connectingUSB: Set<Int> = []
    private var retryTimer: Timer?

    var settings: HostSettings {
        HostSettings(preset: DisplayGeometry.ScalePreset(rawValue: presetRaw) ?? .retina,
                     maxFPS: maxFPS, quality: quality, showsCursor: showsCursor)
    }

    init() {
        // Terminate any older background ExtDisplayHost instance so two processes never
        // compete for usbmuxd or CGVirtualDisplay serial numbers.
        if let bundleID = Bundle.main.bundleIdentifier {
            let myPID = ProcessInfo.processInfo.processIdentifier
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where app.processIdentifier != myPID {
                app.forceTerminate()
            }
        }

        usb.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        usb.startListening()
        usbStatus = "Waiting for a USB device…"

        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retryUSB() }
        }
        if !screenRecordingGranted { ScreenCapturer.requestPermission() }
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        } else if let iconImage = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = iconImage
        }
        let shouldRegisterLogin = launchAtLogin
        Task.detached(priority: .utility) {
            let installed = try? LaunchAtLoginManager.installToApplications()
            if shouldRegisterLogin {
                _ = LaunchAtLoginManager.setEnabled(true)
            }
            if let installed {
                await MainActor.run {
                    HostController.shared.installedAppPath = installed.path
                }
            }
        }
    }

    func installToApplications() {
        if let url = try? LaunchAtLoginManager.installToApplications() {
            installedAppPath = url.path
        }
    }

    func refreshPermissions() {
        let sr = ScreenCapturer.hasPermission()
        if sr != screenRecordingGranted { screenRecordingGranted = sr }
        let ax = InputInjector.isTrusted(prompt: false)
        if ax != accessibilityGranted { accessibilityGranted = ax }
    }

    func requestAccessibility() {
        accessibilityGranted = InputInjector.isTrusted(prompt: true)
    }

    // MARK: USB

    private func handle(_ event: USBMuxClient.DeviceEvent) {
        switch event {
        case .attached(let id, let serial):
            usbDevices[id] = USBDevice(id: id, serial: serial, autoConnect: autoConnectUSB)
            usbStatus = "USB device attached"
            retryUSB()
        case .detached(let id):
            usbDevices[id] = nil
            sessions.filter { $0.transport == .usb(deviceID: id) }.forEach { $0.stop() }
            usbStatus = usbDevices.isEmpty ? "Waiting for a USB device…" : "USB device attached"
        case .listenerFailed(let msg):
            usbStatus = msg
        }
    }

    private func retryUSB() {
        for device in usbDevices.values where device.autoConnect {
            connectUSB(device.id)
        }
    }

    func session(forUSB id: Int) -> HostSession? {
        sessions.first { $0.transport == .usb(deviceID: id) }
    }

    func connectUSB(_ id: Int) {
        guard session(forUSB: id) == nil, !connectingUSB.contains(id) else { return }
        connectingUSB.insert(id)
        Task.detached(priority: .userInitiated) {
            let result = USBMuxClient.connect(deviceID: id, port: ExtDisplay.port)
            await MainActor.run {
                self.connectingUSB.remove(id)
                switch result {
                case .success(let fd):
                    guard self.usbDevices[id] != nil, self.session(forUSB: id) == nil else { close(fd); return }
                    self.usbDevices[id]?.lastError = nil
                    self.startSession(SocketConnection(fd: fd), transport: .usb(deviceID: id))
                case .failure(.refused):
                    self.usbDevices[id]?.lastError = "Open ExtDisplay on the device"
                case .failure(.failed(let msg)):
                    self.usbDevices[id]?.lastError = msg
                }
            }
        }
    }

    func setUSBAutoConnect(_ id: Int, _ on: Bool) {
        usbDevices[id]?.autoConnect = on
        if on { connectUSB(id) } else { session(forUSB: id)?.stop() }
    }

    // MARK: Sessions

    private func startSession(_ connection: FramedConnection, transport: HostSession.Transport) {
        refreshPermissions()
        let s = HostSession(connection: connection, transport: transport, settings: settings)
        s.onChange = { [weak self] in self?.objectWillChange.send() }
        s.onClosed = { [weak self, weak s] in
            guard let self, let s else { return }
            self.sessions.removeAll { $0.id == s.id }
        }
        sessions.append(s)
        s.start()
    }

    func disconnect(_ session: HostSession) {
        if case .usb(let id) = session.transport {
            usbDevices[id]?.autoConnect = false
        }
        session.stop()
    }

    func disconnectAll() {
        sessions.forEach { $0.stop() }
    }

    private func pushSettings() {
        let s = settings
        sessions.forEach { $0.update(settings: s) }
    }
}
