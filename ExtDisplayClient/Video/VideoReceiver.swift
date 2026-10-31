import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware decoder fed directly from the network queue. Drops frames until a keyframe after any error.
final class VideoReceiver: @unchecked Sendable {
    var requestKeyframe: (() -> Void)?

    private let renderer: MetalRenderer
    private let lock = NSLock()
    private var format: VideoFormat?
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var needsKeyframe = true
    private var lastKeyframeRequest: UInt64 = 0

    private var frames = 0
    private var bytes = 0
    private var decodeMicros: UInt64 = 0

    init(renderer: MetalRenderer) {
        self.renderer = renderer
    }

    func handle(_ message: Message) {
        lock.lock(); defer { lock.unlock() }
        switch message.type {
        case .videoFormat:
            guard let f = try? VideoFormat(decoding: message.payload) else { return }
            if f != format || session == nil { rebuild(with: f) }
        case .videoFrame:
            guard let (header, sample) = try? VideoFrame.decode(message.payload) else { return }
            bytes += message.payload.count
            decode(header: header, sample: sample)
        default:
            break
        }
    }

    private func rebuild(with f: VideoFormat) {
        invalidateSession()
        format = f
        guard let fd = try? f.makeFormatDescription() else {
            formatDescription = nil
            return
        }
        formatDescription = fd
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let spec: [CFString: Any] = [:]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fd,
                                                  decoderSpecification: spec as CFDictionary,
                                                  imageBufferAttributes: attrs as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &s)
        guard status == noErr, let s else { return }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        needsKeyframe = true
    }

    private func decode(header: VideoFrameHeader, sample: Data) {
        if needsKeyframe && !header.isKeyframe {
            askForKeyframe()
            return
        }
        guard let session, let fd = formatDescription,
              let buffer = makeSampleBuffer(data: sample, formatDescription: fd, ptsMicros: header.ptsMicros) else {
            askForKeyframe()
            return
        }
        let start = monotonicMicros()
        var failed = false
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: [],
                                                       infoFlagsOut: nil) { [renderer] status, _, image, _, _ in
            if status == noErr, let image {
                renderer.enqueue(image)
            } else {
                failed = true
            }
        }
        if status != noErr || failed {
            if status == kVTInvalidSessionErr, let f = format { rebuild(with: f) }
            needsKeyframe = true
            askForKeyframe()
            return
        }
        needsKeyframe = false
        frames += 1
        decodeMicros += monotonicMicros() - start
    }

    private func askForKeyframe() {
        let now = monotonicMicros()
        guard now - lastKeyframeRequest > 250_000 else { return }
        lastKeyframeRequest = now
        requestKeyframe?()
    }

    /// Called when returning to the foreground: the decoder may have been torn down by the OS.
    func forceResync() {
        lock.lock()
        if let f = format { rebuild(with: f) }
        needsKeyframe = true
        lastKeyframeRequest = 0
        askForKeyframe()
        lock.unlock()
    }

    func reset() {
        lock.lock()
        invalidateSession()
        format = nil
        formatDescription = nil
        needsKeyframe = true
        lock.unlock()
        renderer.clear()
    }

    private func invalidateSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    func takeStats() -> (frames: Double, bytes: Double, decodeMillis: Double) {
        lock.lock(); defer { lock.unlock() }
        let r = (Double(frames), Double(bytes), frames > 0 ? Double(decodeMicros) / Double(frames) / 1000 : 0)
        frames = 0; bytes = 0; decodeMicros = 0
        return r
    }
}

