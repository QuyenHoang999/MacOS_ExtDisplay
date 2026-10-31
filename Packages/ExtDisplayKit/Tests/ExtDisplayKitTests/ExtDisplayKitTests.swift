import XCTest
import CoreMedia
@testable import ExtDisplayKit

final class FrameCodecTests: XCTestCase {
    func testRoundTripSingle() throws {
        let m = Message(.videoFrame, Data((0..<1000).map { UInt8($0 & 0xff) }))
        var d = FrameDecoder()
        XCTAssertEqual(try d.append(FrameEncoder.encode(m)), [m])
        XCTAssertEqual(d.bufferedByteCount, 0)
    }

    func testChunkedAndCoalesced() throws {
        let msgs = [Message(.hello, Data("hi".utf8)), Message(.requestKeyframe), Message(.ping, Data(repeating: 7, count: 8)),
                    Message(.videoFrame, Data(repeating: 0xAB, count: 70_000))]
        let stream = msgs.map(FrameEncoder.encode).reduce(Data(), +)
        for chunkSize in [1, 3, 5, 17, 4096, stream.count] {
            var d = FrameDecoder()
            var out: [Message] = []
            var i = 0
            while i < stream.count {
                let end = min(i + chunkSize, stream.count)
                out += try d.append(stream.subdata(in: i..<end))
                i = end
            }
            XCTAssertEqual(out, msgs, "chunk size \(chunkSize)")
        }
    }

    func testUnknownTypeSkipped() throws {
        var raw = ByteWriter()
        raw.write(UInt32(3)); raw.write(UInt8(200)); raw.write(UInt16(0xBEEF))
        let good = Message(.bye)
        var d = FrameDecoder()
        XCTAssertEqual(try d.append(raw.data + FrameEncoder.encode(good)), [good])
    }

    func testOversizeThrows() {
        var raw = ByteWriter()
        raw.write(UInt32(FrameDecoder.maxFrameSize + 1)); raw.write(UInt8(4))
        var d = FrameDecoder()
        XCTAssertThrowsError(try d.append(raw.data))
    }
}

final class MessageTests: XCTestCase {
    func testInputEventLayout() throws {
        let events = [InputEvent(kind: .down, pointer: .pencil, x: 0.25, y: 0.75, pressure: 0.5),
                      InputEvent(kind: .scroll, pointer: .finger, x: 0.5, y: 0.5, dx: -0.01, dy: 0.02)]
        let data = InputEvent.encode(events)
        XCTAssertEqual(data.count, 2 * InputEvent.size)
        XCTAssertEqual(try InputEvent.decode(data), events)
        XCTAssertEqual(data[0], InputEvent.Kind.down.rawValue)
        XCTAssertEqual(data[1], InputEvent.Pointer.pencil.rawValue)
    }

    func testHelloCodable() throws {
        let h = Hello(deviceName: "iPad", deviceModel: "iPad", nativeWidth: 2732, nativeHeight: 2048, scale: 2, ppi: 264, maxFPS: 120)
        XCTAssertEqual(try Message.json(.hello, h).decodeJSON(Hello.self), h)
    }

    func testVideoFrameRoundTrip() throws {
        let header = VideoFrameHeader(ptsMicros: 123_456_789, isKeyframe: true, captureToSendMicros: 4321)
        let sample = Data([0, 0, 0, 2, 0x26, 0x01])
        let (h, s) = try VideoFrame.decode(VideoFrame.encode(header: header, sample: sample))
        XCTAssertEqual(h, header)
        XCTAssertEqual(s, sample)
    }

    func testPing() {
        XCTAssertEqual(Message.ping(42).timestampMicros, 42)
    }
}

final class VideoFormatTests: XCTestCase {
    // Real H.264 SPS/PPS for 1280x720 baseline.
    let sps = Data([0x67, 0x42, 0xC0, 0x1F, 0xDA, 0x01, 0x40, 0x16, 0xEC, 0x04, 0x40, 0x00, 0x00, 0x03, 0x00, 0x40,
                    0x00, 0x00, 0x0F, 0x23, 0xC6, 0x0C, 0xA8])
    let pps = Data([0x68, 0xCE, 0x3C, 0x80])

    func testWireRoundTrip() throws {
        let f = VideoFormat(codec: .hevc, nalLengthSize: 4, parameterSets: [Data([1, 2, 3]), Data([4]), Data()])
        XCTAssertEqual(try VideoFormat(decoding: f.encoded()), f)
    }

    func testCoreMediaRoundTrip() throws {
        let f = VideoFormat(codec: .h264, nalLengthSize: 4, parameterSets: [sps, pps])
        let fd = try f.makeFormatDescription()
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        XCTAssertEqual(dims.width, 1280)
        XCTAssertEqual(dims.height, 720)
        XCTAssertEqual(try VideoFormat(formatDescription: fd), f)

        let sample = makeSampleBuffer(data: Data([0, 0, 0, 1, 0x65]), formatDescription: fd, ptsMicros: 1000)
        XCTAssertNotNil(sample)
        XCTAssertEqual(sample?.encodedData, Data([0, 0, 0, 1, 0x65]))
    }
}

final class USBMuxProtocolTests: XCTestCase {
    func testConnectRequestEncoding() throws {
        let data = try USBMuxProtocol.connectRequest(deviceID: 7, port: 50505, tag: 9)
        XCTAssertEqual(USBMuxProtocol.packetLength(header: data), data.count)
        let header = [UInt8](data.prefix(16))
        XCTAssertEqual(Array(header[4..<8]), [1, 0, 0, 0])   // version 1
        XCTAssertEqual(Array(header[8..<12]), [8, 0, 0, 0])  // plist
        XCTAssertEqual(Array(header[12..<16]), [9, 0, 0, 0]) // tag
        let dict = try PropertyListSerialization.propertyList(from: data.dropFirst(16), format: nil) as! [String: Any]
        XCTAssertEqual(dict["MessageType"] as? String, "Connect")
        XCTAssertEqual(dict["DeviceID"] as? Int, 7)
        XCTAssertEqual(dict["PortNumber"] as? Int, 0x49_C5) // 50505 = 0xC549 → byte-swapped
    }

    func testDecodeAttachedDetachedResult() throws {
        func body(_ d: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0)
        }
        XCTAssertEqual(try USBMuxProtocol.decode(body: body(["MessageType": "Result", "Number": 3])), .result(3))
        XCTAssertEqual(try USBMuxProtocol.decode(body: body(["MessageType": "Attached", "DeviceID": 4,
                                                             "Properties": ["ConnectionType": "USB", "SerialNumber": "abc"]])),
                       .attached(deviceID: 4, connectionType: "USB", serial: "abc"))
        XCTAssertEqual(try USBMuxProtocol.decode(body: body(["MessageType": "Detached", "DeviceID": 4])), .detached(deviceID: 4))
    }
}

final class GeometryTests: XCTestCase {
    func testGlobalPointMapping() {
        let b = CGRect(x: 1512, y: -200, width: 1366, height: 1024)
        XCTAssertEqual(DisplayGeometry.globalPoint(x: 0, y: 0, in: b), CGPoint(x: 1512, y: -200))
        XCTAssertEqual(DisplayGeometry.globalPoint(x: 0.5, y: 0.5, in: b), CGPoint(x: 1512 + 683, y: -200 + 512))
        XCTAssertEqual(DisplayGeometry.globalPoint(x: 1.5, y: 1, in: b), CGPoint(x: 1512 + 1365, y: -200 + 1023))
    }

    func testModes() {
        let r = DisplayGeometry.mode(pixelsWide: 2732, pixelsHigh: 2048, preset: .retina)
        XCTAssertEqual([r.pointsWide, r.pointsHigh, r.backingWide, r.backingHigh, r.streamWide, r.streamHigh],
                       [1366, 1024, 2732, 2048, 2732, 2048])
        let m = DisplayGeometry.mode(pixelsWide: 2732, pixelsHigh: 2048, preset: .moreSpace)
        XCTAssertEqual(m.pointsWide, 1820)
        XCTAssertEqual(m.streamWide, 2732)
        XCTAssertTrue(m.hiDPI)
    }

    func testAspectFitAndNormalize() {
        let r = DisplayGeometry.aspectFit(CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(r, CGRect(x: 0, y: 25, width: 100, height: 50))
        let (x, y) = DisplayGeometry.normalize(CGPoint(x: 50, y: 50), in: r)
        XCTAssertEqual(x, 0.5); XCTAssertEqual(y, 0.5)
    }
}
