import Foundation

public enum ExtDisplay {
    public static let protocolVersion = 1
    /// TCP port the iOS client listens on (reached via usbmuxd over USB, or directly over Wi-Fi).
    public static let port: UInt16 = 50505
    public static let bonjourType = "_extdisplay._tcp"
}

/// Wire format of every message: `[UInt32 BE length][UInt8 type][payload]`,
/// where `length` = 1 (type byte) + payload length.
public enum MessageType: UInt8, Sendable, CaseIterable {
    case hello = 1           // client → host (JSON `Hello`)
    case config = 2          // host → client (JSON `StreamConfig`)
    case videoFormat = 3     // host → client (binary `VideoFormat`)
    case videoFrame = 4      // host → client (binary `VideoFrameHeader` + sample data)
    case input = 5           // client → host (binary `InputEvent`, may be batched)
    case requestKeyframe = 6 // client → host (empty)
    case ping = 7            // either way (UInt64 BE timestamp µs)
    case pong = 8            // echo of ping payload
    case bye = 9             // either way (empty)
}

public struct Message: Sendable, Equatable {
    public var type: MessageType
    public var payload: Data

    public init(_ type: MessageType, _ payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }
}

// MARK: - Control messages (JSON)

public struct Hello: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var deviceName: String
    public var deviceModel: String
    /// Drawable size in pixels, in the current orientation.
    public var nativeWidth: Int
    public var nativeHeight: Int
    /// UIScreen.nativeScale (2.0 / 3.0).
    public var scale: Double
    /// Approximate pixel density, used to give the virtual display a realistic physical size.
    public var ppi: Double
    public var maxFPS: Int

    public init(protocolVersion: Int = ExtDisplay.protocolVersion, deviceName: String, deviceModel: String,
                nativeWidth: Int, nativeHeight: Int, scale: Double, ppi: Double, maxFPS: Int) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.scale = scale
        self.ppi = ppi
        self.maxFPS = maxFPS
    }
}

public enum VideoCodec: String, Codable, Sendable {
    case hevc, h264
}

public struct StreamConfig: Codable, Sendable, Equatable {
    /// Encoded stream size in pixels.
    public var width: Int
    public var height: Int
    public var fps: Int
    public var codec: VideoCodec
    /// Size of the Mac virtual display in points (informational, shown in the client HUD).
    public var pointsWide: Int
    public var pointsHigh: Int

    public init(width: Int, height: Int, fps: Int, codec: VideoCodec, pointsWide: Int, pointsHigh: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh
    }
}

extension Message {
    public static func json<T: Encodable>(_ type: MessageType, _ value: T) throws -> Message {
        Message(type, try JSONEncoder().encode(value))
    }

    public func decodeJSON<T: Decodable>(_: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: payload)
    }

    public static func ping(_ micros: UInt64) -> Message {
        var w = ByteWriter(capacity: 8)
        w.write(micros)
        return Message(.ping, w.data)
    }

    public var timestampMicros: UInt64? {
        var r = ByteReader(payload)
        return try? r.readUInt64()
    }
}

// MARK: - Video

/// Codec parameter sets (VPS/SPS/PPS for HEVC, SPS/PPS for H.264).
public struct VideoFormat: Sendable, Equatable {
    public var codec: VideoCodec
    public var nalLengthSize: UInt8
    public var parameterSets: [Data]

    public init(codec: VideoCodec, nalLengthSize: UInt8, parameterSets: [Data]) {
        self.codec = codec
        self.nalLengthSize = nalLengthSize
        self.parameterSets = parameterSets
    }

    public func encoded() -> Data {
        var w = ByteWriter(capacity: 128)
        w.write(codec == .hevc ? UInt8(1) : UInt8(0))
        w.write(nalLengthSize)
        w.write(UInt8(parameterSets.count))
        for ps in parameterSets {
            w.write(UInt32(ps.count))
            w.write(ps)
        }
        return w.data
    }

    public init(decoding data: Data) throws {
        var r = ByteReader(data)
        codec = try r.readUInt8() == 1 ? .hevc : .h264
        nalLengthSize = try r.readUInt8()
        let count = Int(try r.readUInt8())
        var sets: [Data] = []
        for _ in 0..<count {
            let len = Int(try r.readUInt32())
            sets.append(try r.readBytes(len))
        }
        parameterSets = sets
    }
}

public struct VideoFrameHeader: Sendable, Equatable {
    public static let size = 13
    public var ptsMicros: UInt64
    public var isKeyframe: Bool
    /// Time from capture to hand-off to the transport on the host, in µs (latency HUD).
    public var captureToSendMicros: UInt32

    public init(ptsMicros: UInt64, isKeyframe: Bool, captureToSendMicros: UInt32) {
        self.ptsMicros = ptsMicros
        self.isKeyframe = isKeyframe
        self.captureToSendMicros = captureToSendMicros
    }
}

public enum VideoFrame {
    /// Payload = header + length-prefixed NAL units exactly as produced by VideoToolbox.
    public static func encode(header: VideoFrameHeader, sample: Data) -> Data {
        var w = ByteWriter(capacity: VideoFrameHeader.size + sample.count)
        w.write(header.ptsMicros)
        w.write(header.isKeyframe ? UInt8(1) : UInt8(0))
        w.write(header.captureToSendMicros)
        w.write(sample)
        return w.data
    }

    public static func decode(_ payload: Data) throws -> (VideoFrameHeader, Data) {
        var r = ByteReader(payload)
        let pts = try r.readUInt64()
        let flags = try r.readUInt8()
        let c2s = try r.readUInt32()
        return (VideoFrameHeader(ptsMicros: pts, isKeyframe: flags & 1 != 0, captureToSendMicros: c2s), r.readRest())
    }
}

// MARK: - Input

public struct InputEvent: Sendable, Equatable {
    public static let size = 24

    public enum Kind: UInt8, Sendable {
        case down = 0, move = 1, up = 2, hover = 3, scroll = 4, rightClick = 5, cancel = 6
    }

    public enum Pointer: UInt8, Sendable {
        case finger = 0, pencil = 1, mouse = 2
    }

    public var kind: Kind
    public var pointer: Pointer
    /// Normalized position (0…1) within the streamed display.
    public var x: Float
    public var y: Float
    /// 0…1 (pencil force); 1 for fingers.
    public var pressure: Float
    /// Scroll deltas, normalized to the display size (fraction of width/height).
    public var dx: Float
    public var dy: Float

    public init(kind: Kind, pointer: Pointer, x: Float, y: Float, pressure: Float = 1, dx: Float = 0, dy: Float = 0) {
        self.kind = kind
        self.pointer = pointer
        self.x = x
        self.y = y
        self.pressure = pressure
        self.dx = dx
        self.dy = dy
    }

    public func write(to w: inout ByteWriter) {
        w.write(kind.rawValue)
        w.write(pointer.rawValue)
        w.write(UInt16(0))
        w.write(x)
        w.write(y)
        w.write(pressure)
        w.write(dx)
        w.write(dy)
    }

    public static func encode(_ events: [InputEvent]) -> Data {
        var w = ByteWriter(capacity: events.count * size)
        for e in events { e.write(to: &w) }
        return w.data
    }

    public static func decode(_ data: Data) throws -> [InputEvent] {
        guard data.count % size == 0 else { throw ByteReaderError.outOfBounds }
        var r = ByteReader(data)
        var out: [InputEvent] = []
        out.reserveCapacity(data.count / size)
        while r.remaining >= size {
            let kindRaw = try r.readUInt8()
            let pointerRaw = try r.readUInt8()
            _ = try r.readUInt16()
            let e = InputEvent(kind: Kind(rawValue: kindRaw) ?? .cancel,
                               pointer: Pointer(rawValue: pointerRaw) ?? .finger,
                               x: try r.readFloat(), y: try r.readFloat(),
                               pressure: try r.readFloat(),
                               dx: try r.readFloat(), dy: try r.readFloat())
            out.append(e)
        }
        return out
    }
}

