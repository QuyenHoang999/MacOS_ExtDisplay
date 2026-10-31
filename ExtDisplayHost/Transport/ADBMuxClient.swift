import Foundation
import Darwin

/// Minimal client for the Android Debug Bridge (`adb`) daemon on `127.0.0.1:5037`.
/// Discovers USB-connected Android phones/tablets and opens direct USB-C TCP tunnels
/// (`host:transport:<serial>` → `tcp:<port>`) without requiring manual `adb forward` commands.
final class ADBMuxClient: @unchecked Sendable {
    enum DeviceEvent: Sendable {
        case attached(serial: String)
        case detached(serial: String)
    }

    var onEvent: (@Sendable (DeviceEvent) -> Void)?

    private let queue = DispatchQueue(label: "extdisplay.adbmux", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var knownSerials: Set<String> = []
    private var triedStartingServer = false

    func startListening() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .seconds(2))
            t.setEventHandler { [weak self] in
                self?.pollDevices()
            }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.knownSerials.removeAll()
        }
    }

    private func pollDevices() {
        guard let response = Self.queryADB("host:devices") else {
            if !triedStartingServer {
                triedStartingServer = true
                Self.tryStartADBServer()
            }
            for serial in knownSerials {
                onEvent?(.detached(serial: serial))
            }
            knownSerials.removeAll()
            return
        }

        var current: Set<String> = []
        for line in response.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t")
            guard parts.count >= 2 else { continue }
            let serial = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let state = String(parts[1]).trimmingCharacters(in: .whitespaces)
            // Ignore TCP/Wi-Fi adb targets (which contain ':') so we only use USB-C devices.
            if state == "device" && !serial.isEmpty && !serial.contains(":") {
                current.insert(serial)
            }
        }

        for added in current.subtracting(knownSerials) {
            onEvent?(.attached(serial: added))
        }
        for removed in knownSerials.subtracting(current) {
            onEvent?(.detached(serial: removed))
        }
        knownSerials = current
    }

    // MARK: - Direct USB-C Tunnel (`host:transport:<serial>` + `tcp:<port>`)

    /// Opens a fresh connection to `127.0.0.1:5037`, selects the Android USB device `serial`,
    /// and connects to TCP `port` on the Android phone. On success, the returned `fd` is a raw
    /// stream connected directly to the Android client's `ServerSocket`.
    static func connect(serial: String, port: UInt16) -> Result<Int32, USBMuxClient.ConnectError> {
        let fd = openADBSocket()
        guard fd >= 0 else {
            return .failure(.failed("ADB daemon not running on 127.0.0.1:5037"))
        }

        switch sendADBCommand(fd: fd, command: "host:transport:\(serial)") {
        case .success:
            break
        case .failure(let err):
            Darwin.close(fd)
            return .failure(err)
        }

        switch sendADBCommand(fd: fd, command: "tcp:\(port)") {
        case .success:
            return .success(fd)
        case .failure(let err):
            Darwin.close(fd)
            return .failure(err)
        }
    }

    // MARK: - Low-level ADB Wire Helpers

    private static func openADBSocket() -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return -1 }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(5037).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    private static func sendADBCommand(fd: Int32, command: String) -> Result<Void, USBMuxClient.ConnectError> {
        let payload = Array(command.utf8)
        let prefix = String(format: "%04X", payload.count)
        let packet = Array(prefix.utf8) + payload
        guard writeAll(fd: fd, bytes: packet) else {
            return .failure(.failed("ADB socket write failed"))
        }
        guard let statusBytes = readExact(fd: fd, count: 4),
              let status = String(bytes: statusBytes, encoding: .utf8) else {
            return .failure(.failed("ADB socket read failed"))
        }
        if status == "OKAY" {
            return .success(())
        }
        if status == "FAIL",
           let lenHex = readExact(fd: fd, count: 4),
           let lenStr = String(bytes: lenHex, encoding: .utf8),
           let len = Int(lenStr, radix: 16),
           let errBytes = readExact(fd: fd, count: len),
           let errMsg = String(bytes: errBytes, encoding: .utf8) {
            if errMsg.localizedCaseInsensitiveContains("Connection refused") || errMsg.localizedCaseInsensitiveContains("closed") {
                return .failure(.refused)
            }
            return .failure(.failed("ADB: \(errMsg)"))
        }
        return .failure(.failed("ADB error (\(status))"))
    }

    private static func queryADB(_ command: String) -> String? {
        let fd = openADBSocket()
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        guard case .success = sendADBCommand(fd: fd, command: command) else { return nil }
        guard let lenHex = readExact(fd: fd, count: 4),
              let lenStr = String(bytes: lenHex, encoding: .utf8),
              let len = Int(lenStr, radix: 16) else { return nil }
        if len == 0 { return "" }
        guard let body = readExact(fd: fd, count: len) else { return nil }
        return String(bytes: body, encoding: .utf8)
    }

    private static func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    private static func readExact(fd: Int32, count: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count)
        var readCount = 0
        while readCount < count {
            let n = buf.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: readCount), count - readCount)
            }
            if n <= 0 { return nil }
            readCount += n
        }
        return buf
    }

    private static func tryStartADBServer() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        guard let adbPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: adbPath)
        proc.arguments = ["start-server"]
        try? proc.run()
    }
}
