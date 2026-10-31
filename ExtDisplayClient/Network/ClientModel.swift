import Foundation
import Network
import UIKit
import SwiftUI

struct ClientStats: Equatable {
    var fps: Double = 0
    var mbps: Double = 0
    var rttMillis: Double = 0
    var decodeMillis: Double = 0
}

/// Automatically listens for the Mac host over USB-C (usbmuxd → loopback) and runs one session.
@MainActor
final class ClientModel: ObservableObject {
    enum State: Equatable {
        case waiting
        case connected
        case streaming
    }

    @Published private(set) var state: State = .waiting
    @Published private(set) var statusMessage = "Waiting for USB-C connection…"
    @Published private(set) var config: StreamConfig?
    @Published private(set) var stats = ClientStats()
    @Published private(set) var transportLabel = "USB"
    @Published private(set) var screenInfo: ScreenInfo?

    /// Owned by the model so the decoder can push frames straight to it off the main thread.
    let renderer = MetalRenderer()
    private let receiver: VideoReceiver

    private var listener: NWListener?
    private var connection: NWFramedConnection?
    private var lastSentHello: Hello?
    private var helloWork: DispatchWorkItem?
    private var timer: Timer?
    private var wasBackgrounded = false
    private var connectedTicks = 0
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    struct ScreenInfo: Equatable {
        var pixelsWide: Int
        var pixelsHigh: Int
        var scale: Double
        var maxFPS: Int
    }

    init() {
        receiver = VideoReceiver(renderer: renderer)
        startListener()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: USB-only Listener (usbmuxd forwards over loopback)

    private func startListener() {
        listener?.cancel()
        do {
            let params = NWFramedConnection.tcpParameters()
            params.includePeerToPeer = false
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: ExtDisplay.port)!)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === l else { return }
                    switch state {
                    case .failed(let error):
                        self.statusMessage = "Listener error: \(error.localizedDescription). Retrying…"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.startListener() }
                    case .ready:
                        if self.connection == nil {
                            self.statusMessage = "Waiting for USB-C connection…"
                        }
                    default:
                        break
                    }
                }
            }
            l.start(queue: DispatchQueue(label: "extdisplay.listener"))
            listener = l
        } catch {
            statusMessage = "Cannot listen on port \(ExtDisplay.port): \(error.localizedDescription)"
        }
    }

    private func accept(_ nw: NWConnection) {
        // Newest host wins (e.g. after a cable replug the old socket may linger).
        connection?.close()
        receiver.reset()

        let conn = NWFramedConnection(connection: nw)
        transportLabel = "USB"
        conn.onReady = { [weak self] in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                self.state = .connected
                self.connectedTicks = 0
                self.statusMessage = "Connected over USB-C. Setting up display…"
                self.lastSentHello = nil
                self.sendHelloIfNeeded()
            }
        }
        conn.onMessage = { [weak self, receiver] message in
            switch message.type {
            case .videoFormat, .videoFrame:
                receiver.handle(message) // stays on the network queue – no main-thread hop
            case .ping:
                conn.send(Message(.pong, message.payload))
            default:
                Task { @MainActor in self?.handleControl(message, from: conn) }
            }
        }
        conn.onClose = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                self.connection = nil
                self.receiver.reset()
                self.config = nil
                self.state = .waiting
                self.statusMessage = "Waiting for USB-C connection…"
                UIApplication.shared.isIdleTimerDisabled = false
                if self.listener == nil || self.listener?.state != .ready {
                    self.startListener()
                }
            }
        }
        receiver.requestKeyframe = { [weak conn] in conn?.send(Message(.requestKeyframe)) }
        connection = conn
        conn.start()
    }

    private func handleControl(_ message: Message, from conn: NWFramedConnection) {
        guard conn === connection else { return }
        switch message.type {
        case .config:
            guard let cfg = try? message.decodeJSON(StreamConfig.self) else { return }
            config = cfg
            state = .streaming
            UIApplication.shared.isIdleTimerDisabled = true
        case .pong:
            if let t = message.timestampMicros {
                stats.rttMillis = Double(monotonicMicros() &- t) / 1000
            }
        case .bye:
            conn.close()
        default:
            break
        }
    }

    // MARK: Screen / hello

    func updateScreen(_ info: ScreenInfo) {
        guard info != screenInfo else { return }
        screenInfo = info
        // Debounce rotations so the Mac doesn't rebuild the display mid-animation.
        helloWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendHelloIfNeeded() }
        helloWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func sendHelloIfNeeded() {
        guard let conn = connection, let s = screenInfo, s.pixelsWide > 0 else { return }
        let idiom = UIDevice.current.userInterfaceIdiom
        let ppi: Double = idiom == .phone ? (s.scale >= 3 ? 460 : 326) : 264
        let hello = Hello(deviceName: UIDevice.current.name, deviceModel: UIDevice.current.model,
                          nativeWidth: s.pixelsWide, nativeHeight: s.pixelsHigh, scale: s.scale, ppi: ppi,
                          maxFPS: s.maxFPS)
        guard hello != lastSentHello, let msg = try? Message.json(.hello, hello) else { return }
        lastSentHello = hello
        conn.send(msg)
    }

    // MARK: Input

    func send(_ events: [InputEvent]) {
        guard !events.isEmpty, state == .streaming else { return }
        connection?.send(Message(.input, InputEvent.encode(events)))
    }

    // MARK: Lifecycle (Maintain connection when app is backgrounded/exited)

    func scenePhaseChanged(active: Bool) {
        if active {
            endBackgroundKeepAlive()
            if listener == nil || listener?.state != .ready {
                startListener()
            }
            if wasBackgrounded {
                wasBackgrounded = false
                if connection != nil {
                    receiver.forceResync()
                }
            }
        } else {
            wasBackgrounded = true
            beginBackgroundKeepAlive()
        }
    }

    private func beginBackgroundKeepAlive() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ExtDisplayKeepAlive") { [weak self] in
            Task { @MainActor in self?.endBackgroundKeepAlive() }
        }
    }

    private func endBackgroundKeepAlive() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func tick() {
        if listener == nil || listener?.state != .ready {
            startListener()
        }
        connection?.send(.ping(monotonicMicros()))
        if state == .connected, connection != nil {
            connectedTicks += 1
            if connectedTicks >= 4 {
                connectedTicks = 0
                lastSentHello = nil
                sendHelloIfNeeded()
            }
        } else {
            connectedTicks = 0
        }
        let r = receiver.takeStats()
        stats.fps = r.frames
        stats.mbps = r.bytes * 8 / 1_000_000
        stats.decodeMillis = r.decodeMillis
    }
}
