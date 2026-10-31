import Foundation

public enum FrameCodecError: Error, Equatable {
    case frameTooLarge(Int)
    case emptyFrame
}

public enum FrameEncoder {
    public static let headerSize = 5

    public static func encode(_ message: Message) -> Data {
        var w = ByteWriter(capacity: headerSize + message.payload.count)
        w.write(UInt32(message.payload.count + 1))
        w.write(message.type.rawValue)
        w.write(message.payload)
        return w.data
    }
}

/// Reassembles length-prefixed messages from an arbitrary stream of byte chunks.
/// Not thread-safe; feed it from a single serial queue.
public struct FrameDecoder {
    public static let maxFrameSize = 32 * 1024 * 1024

    private var buffer = Data()

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    /// Appends bytes and returns every complete message. Unknown message types are skipped
    /// (forward compatibility); malformed lengths throw.
    public mutating func append(_ chunk: Data) throws -> [Message] {
        buffer.append(chunk)
        var messages: [Message] = []
        var offset = buffer.startIndex

        while buffer.endIndex - offset >= FrameEncoder.headerSize {
            var length = 0
            for i in 0..<4 { length = length << 8 | Int(buffer[offset + i]) }
            guard length >= 1 else { throw FrameCodecError.emptyFrame }
            guard length <= Self.maxFrameSize else { throw FrameCodecError.frameTooLarge(length) }
            guard buffer.endIndex - offset >= 4 + length else { break }

            let typeByte = buffer[offset + 4]
            let payloadStart = offset + 5
            let payloadEnd = offset + 4 + length
            if let type = MessageType(rawValue: typeByte) {
                messages.append(Message(type, buffer.subdata(in: payloadStart..<payloadEnd)))
            }
            offset = payloadEnd
        }

        if offset > buffer.startIndex {
            buffer = buffer.subdata(in: offset..<buffer.endIndex)
        }
        return messages
    }
}

