import Foundation
import VideoToolbox
import CoreMedia

/// Low-latency hardware encoder. Prefers HEVC with low-latency rate control, falls back to H.264.
final class VideoEncoder: @unchecked Sendable {
    struct Output {
        var format: VideoFormat?   // non-nil when parameter sets changed (always on first keyframe)
        var data: Data
        var isKeyframe: Bool
        var ptsMicros: UInt64
        var encodeMicros: UInt32
    }

    var onOutput: ((Output) -> Void)?
    private(set) var codec: VideoCodec = .hevc

    private var session: VTCompressionSession?
    private var lastFormat: VideoFormat?
    private var forceKeyframe = true
    private let lock = NSLock()

    let width: Int
    let height: Int
    let fps: Int
    var bitrate: Int { didSet { applyBitrate() } }

    init(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        try createSession()
    }

    deinit { invalidate() }

    private func createSession() throws {
        let attempts: [(CMVideoCodecType, VideoCodec, Bool)] = [
            (kCMVideoCodecType_HEVC, .hevc, true),
            (kCMVideoCodecType_H264, .h264, true),
            (kCMVideoCodecType_HEVC, .hevc, false),
        ]
        var lastStatus: OSStatus = -1
        for (type, codec, lowLatency) in attempts {
            var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            let sourceAttrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var s: VTCompressionSession?
            lastStatus = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                                                    codecType: type, encoderSpecification: spec as CFDictionary,
                                                    imageBufferAttributes: sourceAttrs as CFDictionary,
                                                    compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                    compressionSessionOut: &s)
            if lastStatus == noErr, let s {
                self.session = s
                self.codec = codec
                configure(s, codec: codec, lowLatencyRateControl: lowLatency)
                return
            }
        }
        throw HostError.encoder(lastStatus)
    }

    private func configure(_ s: VTCompressionSession, codec: VideoCodec, lowLatencyRateControl: Bool) {
        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(s, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 30 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 30) as CFNumber)
        if !lowLatencyRateControl {
            set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
            set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber)
        }
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        applyBitrate()
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    private func applyBitrate() {
        guard let s = session else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // Cap bursts at 1.5× average over a 1 s window so keyframes don't flood the link.
        let limits = [Double(bitrate) * 1.5 / 8, 1.0] as CFArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        lock.lock()
        let key = forceKeyframe
        forceKeyframe = false
        lock.unlock()

        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let start = monotonicMicros()
        let ptsMicros = UInt64(max(0, pts.seconds) * 1_000_000)

        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                     duration: .invalid, frameProperties: props,
                                                     infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample, let data = sample.encodedData else { return }
            // Attach parameter sets to every keyframe (and whenever they change) so a client
            // that joins late or recovers from an error can always (re)build its decoder.
            let isKey = sample.isKeyframe
            var format: VideoFormat?
            if let fd = CMSampleBufferGetFormatDescription(sample), let f = try? VideoFormat(formatDescription: fd),
               isKey || f != self.lastFormat {
                self.lastFormat = f
                format = f
            }
            self.onOutput?(Output(format: format, data: data, isKeyframe: isKey, ptsMicros: ptsMicros,
                                  encodeMicros: UInt32(clamping: monotonicMicros() - start)))
        }
        if status != noErr {
            requestKeyframe()
        }
    }

    /// The last parameter sets (resent when a client re-requests a keyframe).
    var currentFormat: VideoFormat? { lastFormat }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }
}
