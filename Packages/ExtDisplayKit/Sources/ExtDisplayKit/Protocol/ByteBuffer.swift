import Foundation

/// Big-endian binary writer used for the hot-path wire structures.
public struct ByteWriter {
    public private(set) var data: Data

    public init(capacity: Int = 64) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    public mutating func write(_ v: UInt8) { data.append(v) }

    public mutating func write(_ v: UInt16) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    public mutating func write(_ v: UInt32) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    public mutating func write(_ v: UInt64) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    public mutating func write(_ v: Float) { write(v.bitPattern) }

    public mutating func write(_ bytes: Data) { data.append(bytes) }
}

public enum ByteReaderError: Error, Equatable {
    case outOfBounds
}

/// Big-endian binary reader. Works on any `Data` slice (index-safe).
public struct ByteReader {
    private let data: Data
    private var cursor: Int

    public init(_ data: Data) {
        self.data = data
        self.cursor = data.startIndex
    }

    public var remaining: Int { data.endIndex - cursor }

    public mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw ByteReaderError.outOfBounds }
        defer { cursor += 1 }
        return data[cursor]
    }

    public mutating func readUInt16() throws -> UInt16 {
        UInt16(try readUInt8()) << 8 | UInt16(try readUInt8())
    }

    public mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw ByteReaderError.outOfBounds }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(data[cursor + i]) }
        cursor += 4
        return v
    }

    public mutating func readUInt64() throws -> UInt64 {
        UInt64(try readUInt32()) << 32 | UInt64(try readUInt32())
    }

    public mutating func readFloat() throws -> Float { Float(bitPattern: try readUInt32()) }

    public mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw ByteReaderError.outOfBounds }
        defer { cursor += count }
        return data.subdata(in: cursor..<(cursor + count))
    }

    public mutating func readRest() -> Data {
        defer { cursor = data.endIndex }
        return data.subdata(in: cursor..<data.endIndex)
    }
}

