import Foundation
import CoreMedia

public enum VideoFormatError: Error {
    case missingParameterSets
    case status(OSStatus)
}

extension VideoFormat {
    /// Extracts parameter sets from an encoder-produced format description.
    public init(formatDescription fd: CMFormatDescription) throws {
        let subtype = CMFormatDescriptionGetMediaSubType(fd)
        let isHEVC = subtype == kCMVideoCodecType_HEVC
        var count = 0
        var nalLen: Int32 = 4
        let status: OSStatus = isHEVC
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: &nalLen)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: &nalLen)
        guard status == noErr else { throw VideoFormatError.status(status) }
        guard count > 0 else { throw VideoFormatError.missingParameterSets }

        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let s: OSStatus = isHEVC
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil)
            guard s == noErr, let ptr else { throw VideoFormatError.status(s) }
            sets.append(Data(bytes: ptr, count: size))
        }
        self.init(codec: isHEVC ? .hevc : .h264, nalLengthSize: UInt8(nalLen), parameterSets: sets)
    }

    /// Rebuilds a format description on the decoding side.
    public func makeFormatDescription() throws -> CMVideoFormatDescription {
        guard !parameterSets.isEmpty else { throw VideoFormatError.missingParameterSets }
        // Keep the Data buffers alive and contiguous while CoreMedia copies them.
        let buffers = parameterSets.map { [UInt8]($0) }
        var fd: CMVideoFormatDescription?
        let status: OSStatus = withPointers(buffers) { pointers, sizes in
            switch codec {
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: buffers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(nalLengthSize), extensions: nil, formatDescriptionOut: &fd)
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: buffers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(nalLengthSize), formatDescriptionOut: &fd)
            }
        }
        guard status == noErr, let fd else { throw VideoFormatError.status(status) }
        return fd
    }
}

private func withPointers<R>(_ buffers: [[UInt8]],
                             _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
    let sizes = buffers.map(\.count)
    let raw = buffers.map { buf -> UnsafeMutablePointer<UInt8> in
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(buf.count, 1))
        p.initialize(from: buf, count: buf.count)
        return p
    }
    defer { raw.forEach { $0.deallocate() } }
    let pointers = raw.map { UnsafePointer($0) }
    return pointers.withUnsafeBufferPointer { pp in
        sizes.withUnsafeBufferPointer { sp in body(pp.baseAddress!, sp.baseAddress!) }
    }
}

extension CMSampleBuffer {
    /// True when the encoder produced a sync (IDR) frame.
    public var isKeyframe: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// Copies the (length-prefixed) encoded bytes out of the block buffer.
    public var encodedData: Data? {
        guard let block = CMSampleBufferGetDataBuffer(self) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }
}

/// Wraps received encoded bytes into a CMSampleBuffer ready for VTDecompressionSession.
public func makeSampleBuffer(data: Data, formatDescription: CMVideoFormatDescription, ptsMicros: UInt64) -> CMSampleBuffer? {
    var block: CMBlockBuffer?
    let length = data.count
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                             blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                             offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                             blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
    let copied = data.withUnsafeBytes { raw in
        CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
    }
    guard copied == kCMBlockBufferNoErr else { return nil }

    var timing = CMSampleTimingInfo(duration: .invalid,
                                    presentationTimeStamp: CMTime(value: CMTimeValue(ptsMicros), timescale: 1_000_000),
                                    decodeTimeStamp: .invalid)
    var sizes = [length]
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
                                    sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                    sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr
    else { return nil }
    if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
       CFArrayGetCount(attachments) > 0 {
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
}

/// Monotonic microsecond clock.
public func monotonicMicros() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000
}

