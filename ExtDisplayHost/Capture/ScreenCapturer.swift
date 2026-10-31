import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Captures a single display with ScreenCaptureKit, delivering NV12 IOSurface-backed pixel buffers.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Called on the capture queue with every *changed* frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private let queue = DispatchQueue(label: "extdisplay.capture", qos: .userInteractive)

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, showsCursor: Bool = true) async throws {
        // A freshly created virtual display can take a moment to show up in shareable content.
        var scDisplay: SCDisplay?
        for _ in 0..<30 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            scDisplay = content.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let scDisplay else { throw HostError.capture("display \(displayID) not found in shareable content") }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = Self.makeConfig(width: width, height: height, fps: fps, showsCursor: showsCursor)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.configuration = config
        self.stream = stream
    }

    /// Updates cursor visibility or stream dimensions/FPS live without stopping capture or touching the display.
    func update(width: Int? = nil, height: Int? = nil, fps: Int? = nil, showsCursor: Bool? = nil) async {
        guard let stream, let config = configuration else { return }
        if let width { config.width = width }
        if let height { config.height = height }
        if let fps { config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps)) }
        if let showsCursor { config.showsCursor = showsCursor }
        try? await stream.updateConfiguration(config)
    }

    private static func makeConfig(width: Int, height: Int, fps: Int, showsCursor: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 4
        config.showsCursor = showsCursor
        config.scalesToFit = true
        config.capturesAudio = false
        return config
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        self.configuration = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        self.configuration = nil
        onStop?(error)
    }
}
