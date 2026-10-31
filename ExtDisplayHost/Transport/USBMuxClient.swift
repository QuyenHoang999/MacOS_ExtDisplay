import Foundation
import Darwin

/// Minimal usbmuxd client: watches for USB-attached iOS devices and opens TCP tunnels to them.
final class USBMuxClient: @unchecked Sendable {
    enum DeviceEvent {
        case attached(deviceID: Int, serial: String)
        case detached(deviceID: Int)
        case listenerFailed(String)
    }

    var onEvent: ((DeviceEvent) -> Void)?

    private var listenFD: Int32 = -1
    private let listenQueue = DispatchQueue(label: "extdisplay.usbmux.listen")
    private var running = false
    private var tag: UInt32 = 1

    // MARK: Socket helpers

    static func openSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HostError.usbmux("socket() failed: \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = USBMuxProtocol.socketPath
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8.prefix(raw.count - 1))
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        guard result == 0 else {
            let e = errno
            close(fd)
            throw HostError.usbmux("cannot connect to \(path) (errno \(e)). Is the app sandboxed?")
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }

    static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var buf = [UInt8](repeating: 0, count: count)
        var off = 0
        while off < count {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + off, count - off) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            off += n
        }
        return Data(buf)
    }

    static func readPacket(_ fd: Int32) -> USBMuxProtocol.Packet? {
        guard let header = readExactly(fd, USBMuxProtocol.headerSize),
              let total = USBMuxProtocol.packetLength(header: header),
              total >= USBMuxProtocol.headerSize, total < 1 << 20,
              let body = readExactly(fd, total - USBMuxProtocol.headerSize) else { return nil }
        return try? USBMuxProtocol.decode(body: body)
    }

    // MARK: Listening for devices

    func startListening() {
        guard !running else { return }
        running = true
        listenQueue.async { [weak self] in self?.listenLoop() }
    }

    func stopListening() {
        running = false
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR) }
    }

    private func listenLoop() {
        while running {
            do {
                let fd = try Self.openSocket()
                listenFD = fd
                guard Self.writeAll(fd, try USBMuxProtocol.listenRequest(tag: nextTag())) else {
                    throw HostError.usbmux("Listen write failed")
                }
                while running, let packet = Self.readPacket(fd) {
                    switch packet {
                    case .result(let code) where code != 0:
                        onEvent?(.listenerFailed("usbmuxd Listen result \(code)"))
                    case .attached(let id, let type, let serial) where type == "USB":
                        onEvent?(.attached(deviceID: id, serial: serial))
                    case .detached(let id):
                        onEvent?(.detached(deviceID: id))
                    default:
                        break
                    }
                }
                close(fd)
                listenFD = -1
            } catch {
                onEvent?(.listenerFailed(error.localizedDescription))
            }
            if running { Thread.sleep(forTimeInterval: 2) } // usbmuxd restarted / unavailable – retry
        }
    }

    private func nextTag() -> UInt32 {
        tag &+= 1
        return tag
    }

    // MARK: Connecting

    enum ConnectError: Error {
        case refused        // the iOS app isn't listening (not open / backgrounded)
        case failed(String)
    }

    /// Opens a tunnel to `port` on the device. Blocking – call off the main thread.
    static func connect(deviceID: Int, port: UInt16) -> Result<Int32, ConnectError> {
        do {
            let fd = try openSocket()
            guard writeAll(fd, try USBMuxProtocol.connectRequest(deviceID: deviceID, port: port, tag: 1)) else {
                close(fd)
                return .failure(.failed("write failed"))
            }
            guard let packet = readPacket(fd) else {
                close(fd)
                return .failure(.failed("no reply from usbmuxd"))
            }
            switch packet {
            case .result(0):
                return .success(fd) // fd is now a raw byte pipe to the device
            case .result(3):
                close(fd)
                return .failure(.refused)
            case .result(let code):
                close(fd)
                return .failure(.failed("usbmuxd result \(code)"))
            default:
                close(fd)
                return .failure(.failed("unexpected reply"))
            }
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}

