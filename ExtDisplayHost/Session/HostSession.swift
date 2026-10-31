import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo

struct HostSettings: Equatable {
    var preset: DisplayGeometry.ScalePreset = .retina
    var maxFPS: Int = 60
    /// Bits per pixel per frame used to derive the bitrate (0.05 … 0.3).
    var quality: Double = 0.12
    var showsCursor: Bool = true

    func bitrate(width: Int, height: Int, fps: Int) -> Int {
        let raw = Double(width * height * fps) * quality
        return Int(min(max(raw, 4_000_000), 150_000_000))
    }
}

struct SessionStats: Equatable {
    var fps: Double = 0
    var mbps: Double = 0
    var rttMillis: Double = 0
    var encodeMillis: Double = 0
    var droppedFrames: Int = 0
}

/// Drives one connected USB client: virtual display → capture → encode → transport, and input back.
/// Control flow runs on the main actor; the video path runs on capture / encoder queues.
@MainActor
final class HostSession: Identifiable {
    enum State: Equatable {
        case connecting
        case waitingForHello
        case streaming(StreamConfig)
        case failed(String)
        case closed
    }

    nonisolated let id = UUID()
    let transport: Transport
    private(set) var state: State = .connecting { didSet { onChange?() } }
    private(set) var deviceName: String?
    private(set) var stats = SessionStats() { didSet { onChange?() } }
    var onChange: (() -> Void)?
    var onClosed: (() -> Void)?

    enum Transport: Equatable {
        case usb(deviceID: Int)
        var label: String { "USB" }
    }

    private let connection: FramedConnection
    private var settings: HostSettings
    private let virtualDisplay = VirtualDisplayManager()
    private let injector = InputInjector()
    private var capturer: ScreenCapturer?
    private var pipeline: VideoPipeline?
    private var lastHello: Hello?
    private var timer: Timer?
    private var configureTask: Task<Void, Never>?

    init(connection: FramedConnection, transport: Transport, settings: HostSettings) {
        self.connection = connection
        self.transport = transport
        self.settings = settings
        injector.boundsProvider = { [weak virtualDisplay] in virtualDisplay?.bounds ?? .zero }
    }

    func start() {
        connection.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        connection.onClose = { [weak self] error in
            Task { @MainActor in self?.teardown(reason: error?.localizedDescription) }
        }
        state = .waitingForHello
        connection.start()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        connection.send(Message(.bye))
        connection.close()
        teardown(reason: nil)
    }

    func update(settings: HostSettings) {
        let old = self.settings
        guard settings != old else { return }
        self.settings = settings

        // Resolution or max FPS change: update display mode & pipeline.
        if settings.preset != old.preset || settings.maxFPS != old.maxFPS {
            if let hello = lastHello {
                configure(for: hello)
            }
            return
        }

        // Cursor toggle: update SCStream configuration live in-place without touching the virtual display.
        if settings.showsCursor != old.showsCursor, let capturer {
            let show = settings.showsCursor
            let bounds = virtualDisplay.bounds
            let pipe = pipeline
            Task { @MainActor in
                await capturer.update(showsCursor: show)
                Self.nudgeCursorIfOnDisplay(bounds)
                pipe?.requestKeyframe()
            }
        }

        // Quality / bitrate slider: update encoder bitrate live in-place.
        if settings.quality != old.quality, let p = pipeline, case .streaming(let c) = state {
            p.encoder.bitrate = settings.bitrate(width: c.width, height: c.height, fps: c.fps)
        }
    }

    private static func nudgeCursorIfOnDisplay(_ bounds: CGRect) {
        guard bounds.width > 0,
              let pos = CGEvent(source: nil)?.location,
              bounds.contains(pos) else { return }
        let nudged = CGPoint(x: min(pos.x + 1, bounds.maxX - 1), y: pos.y)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: nudged, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pos, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    var displayBounds: CGRect { virtualDisplay.bounds }

    // MARK: Messages

    private func handle(_ message: Message) {
        switch message.type {
        case .hello:
            guard let hello = try? message.decodeJSON(Hello.self) else { return }
            deviceName = hello.deviceName
            if hello != lastHello { configure(for: hello) }
        case .input:
            if let events = try? InputEvent.decode(message.payload) { injector.handle(events) }
        case .requestKeyframe:
            pipeline?.requestKeyframe()
        case .ping:
            connection.send(Message(.pong, message.payload))
        case .pong:
            if let t = message.timestampMicros {
                stats.rttMillis = Double(monotonicMicros() &- t) / 1000
            }
        case .bye:
            connection.close()
        default:
            break
        }
    }

    // MARK: Pipeline

    private func configure(for hello: Hello) {
        lastHello = hello
        let previousTask = configureTask
        let settings = self.settings
        configureTask = Task { @MainActor [weak self] in
            // Wait for any in-flight configuration to finish before reconfiguring so WindowServer
            // never sees a display destroyed mid-registration.
            _ = await previousTask?.result
            guard let self, self.lastHello == hello, self.state != .closed else { return }

            await self.stopCaptureAndEncoder()
            do {
                let fps = min(settings.maxFPS, max(30, hello.maxFPS))
                let mode = DisplayGeometry.mode(pixelsWide: hello.nativeWidth, pixelsHigh: hello.nativeHeight,
                                                preset: settings.preset)
                let displayID = try self.virtualDisplay.create(
                    name: hello.deviceName, pointsWide: mode.pointsWide, pointsHigh: mode.pointsHigh,
                    hiDPI: mode.hiDPI, refreshRate: Double(fps),
                    sizeInMillimeters: DisplayGeometry.physicalSize(pixelsWide: hello.nativeWidth,
                                                                     pixelsHigh: hello.nativeHeight, ppi: hello.ppi))
                guard !Task.isCancelled, self.state != .closed else { return }

                let bitrate = settings.bitrate(width: mode.streamWide, height: mode.streamHigh, fps: fps)
                let encoder = try VideoEncoder(width: mode.streamWide, height: mode.streamHigh, fps: fps, bitrate: bitrate)
                let pipeline = VideoPipeline(connection: self.connection, encoder: encoder,
                                             maxPendingBytes: max(1_000_000, bitrate / 8 / 8))
                let capturer = ScreenCapturer()
                capturer.onFrame = { [pipeline] buffer, pts in pipeline.capture(buffer, pts: pts) }
                capturer.onStop = { [weak self] error in
                    Task { @MainActor [weak self] in
                        if let error { self?.state = .failed(error.localizedDescription) }
                    }
                }
                self.pipeline = pipeline
                self.capturer = capturer

                let config = StreamConfig(width: mode.streamWide, height: mode.streamHigh, fps: fps, codec: encoder.codec,
                                          pointsWide: mode.pointsWide, pointsHigh: mode.pointsHigh)
                self.connection.send(try Message.json(.config, config))
                try await capturer.start(displayID: displayID, width: mode.streamWide,
                                         height: mode.streamHigh, fps: fps, showsCursor: settings.showsCursor)
                self.state = .streaming(config)
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func stopCaptureAndEncoder() async {
        injector.reset()
        let c = capturer
        capturer = nil
        pipeline?.invalidate()
        pipeline = nil
        await c?.stop()
    }

    private func stopPipeline() async {
        virtualDisplay.destroy()
        await stopCaptureAndEncoder()
    }

    private func tick() {
        connection.send(.ping(monotonicMicros()))
        if let p = pipeline {
            let s = p.takeStats()
            stats = SessionStats(fps: s.frames, mbps: s.bytes * 8 / 1_000_000, rttMillis: stats.rttMillis,
                                 encodeMillis: s.encodeMillis, droppedFrames: stats.droppedFrames + s.dropped)
        }
    }

    private func teardown(reason: String?) {
        guard state != .closed else { return }
        timer?.invalidate()
        timer = nil
        configureTask?.cancel()
        virtualDisplay.destroy()
        Task { @MainActor in await stopCaptureAndEncoder() }
        if let reason { print("[ExtDisplay] session closed: \(reason)") }
        state = .closed
        onClosed?()
    }
}

/// Off-main video path with back-pressure: frames are dropped *before* encoding when the
/// transport is backed up, so latency never accumulates.
final class VideoPipeline: @unchecked Sendable {
    let encoder: VideoEncoder
    private let connection: FramedConnection
    private let maxPendingBytes: Int
    private let lock = NSLock()
    private var lastBuffer: CVPixelBuffer?
    private var frames = 0
    private var bytes = 0
    private var dropped = 0
    private var encodeMicrosTotal: UInt64 = 0
    private var valid = true
    private let queue = DispatchQueue(label: "extdisplay.encode", qos: .userInteractive)

    init(connection: FramedConnection, encoder: VideoEncoder, maxPendingBytes: Int) {
        self.connection = connection
        self.encoder = encoder
        self.maxPendingBytes = maxPendingBytes
        encoder.onOutput = { [weak self] out in self?.send(out) }
    }

    func capture(_ buffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        lastBuffer = buffer
        let ok = valid
        lock.unlock()
        guard ok else { return }
        if connection.pendingBytes > maxPendingBytes {
            lock.lock(); dropped += 1; lock.unlock()
            return
        }
        encoder.encode(buffer, pts: pts)
    }

    /// Forces a keyframe immediately, re-encoding the last frame if the screen is static.
    func requestKeyframe() {
        encoder.requestKeyframe()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let b = self.lastBuffer
            let ok = self.valid
            self.lock.unlock()
            if ok, let b {
                self.encoder.encode(b, pts: CMTime(value: CMTimeValue(monotonicMicros()), timescale: 1_000_000))
            }
        }
    }

    private func send(_ out: VideoEncoder.Output) {
        if let f = out.format { connection.send(Message(.videoFormat, f.encoded())) }
        let header = VideoFrameHeader(ptsMicros: out.ptsMicros, isKeyframe: out.isKeyframe,
                                      captureToSendMicros: out.encodeMicros)
        let payload = VideoFrame.encode(header: header, sample: out.data)
        connection.send(Message(.videoFrame, payload))
        lock.lock()
        frames += 1
        bytes += payload.count
        encodeMicrosTotal += UInt64(out.encodeMicros)
        lock.unlock()
    }

    func takeStats() -> (frames: Double, bytes: Double, encodeMillis: Double, dropped: Int) {
        lock.lock(); defer { lock.unlock() }
        let r = (Double(frames), Double(bytes), frames > 0 ? Double(encodeMicrosTotal) / Double(frames) / 1000 : 0, dropped)
        frames = 0; bytes = 0; dropped = 0; encodeMicrosTotal = 0
        return r
    }

    func invalidate() {
        lock.lock(); valid = false; lastBuffer = nil; lock.unlock()
        encoder.onOutput = nil
        encoder.invalidate()
    }
}
