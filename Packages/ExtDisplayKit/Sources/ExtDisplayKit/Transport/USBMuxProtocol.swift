import Foundation

/// Encoding/decoding of the usbmuxd plist protocol (version 1, message type 8).
/// Header (little-endian): `length` (incl. 16-byte header), `version`, `message`, `tag`.
public enum USBMuxProtocol {
    public static let socketPath = "/var/run/usbmuxd"
    public static let headerSize = 16
    static let version: UInt32 = 1
    static let plistMessage: UInt32 = 8

    public enum ResultCode: Int, Sendable {
        case ok = 0, badCommand = 1, badDevice = 2, connectionRefused = 3, badVersion = 6
    }

    public enum Packet: Sendable, Equatable {
        case result(Int)
        case attached(deviceID: Int, connectionType: String, serial: String)
        case detached(deviceID: Int)
        case other(String)
    }

    public static func encode(_ dict: [String: Any], tag: UInt32) throws -> Data {
        let body = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        var data = Data(capacity: headerSize + body.count)
        for v in [UInt32(headerSize + body.count), version, plistMessage, tag] {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        data.append(body)
        return data
    }

    static func baseRequest(_ type: String) -> [String: Any] {
        ["MessageType": type,
         "ClientVersionString": "ExtDisplay-1.0",
         "ProgName": "ExtDisplayHost",
         "kLibUSBMuxVersion": 3]
    }

    public static func listenRequest(tag: UInt32) throws -> Data {
        try encode(baseRequest("Listen"), tag: tag)
    }

    public static func connectRequest(deviceID: Int, port: UInt16, tag: UInt32) throws -> Data {
        var d = baseRequest("Connect")
        d["DeviceID"] = deviceID
        d["PortNumber"] = Int(port.bigEndian) // usbmuxd expects network byte order
        return try encode(d, tag: tag)
    }

    /// Reads the total packet length from a 16-byte header.
    public static func packetLength(header: Data) -> Int? {
        guard header.count >= headerSize else { return nil }
        let b = [UInt8](header.prefix(4))
        return Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
    }

    /// Decodes the plist body of a packet (without header).
    public static func decode(body: Data) throws -> Packet {
        guard let dict = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any],
              let type = dict["MessageType"] as? String else { return .other("invalid") }
        switch type {
        case "Result":
            return .result((dict["Number"] as? NSNumber)?.intValue ?? -1)
        case "Attached":
            let props = dict["Properties"] as? [String: Any] ?? [:]
            return .attached(deviceID: (dict["DeviceID"] as? NSNumber)?.intValue ?? -1,
                             connectionType: props["ConnectionType"] as? String ?? "",
                             serial: props["SerialNumber"] as? String ?? "")
        case "Detached":
            return .detached(deviceID: (dict["DeviceID"] as? NSNumber)?.intValue ?? -1)
        default:
            return .other(type)
        }
    }
}

