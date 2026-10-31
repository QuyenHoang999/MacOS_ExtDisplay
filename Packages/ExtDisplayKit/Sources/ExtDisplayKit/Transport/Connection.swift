import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

/// A bidirectional message pipe. Callbacks are delivered on the connection's internal serial queue.
public protocol FramedConnection: AnyObject, Sendable {
    var onMessage: (@Sendable (Message) -> Void)? { get set }
    var onClose: (@Sendable (Error?) -> Void)? { get set }
    /// Bytes handed to `send` that have not yet been written to the transport.
    /// Producers use this for back-pressure (drop frames instead of building latency).
    var pendingBytes: Int { get }
    func start()
    func send(_ message: Message)
    func close()
}

// MARK: - Back-pressure counter

final class PendingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add(_ n: Int) { lock.lock(); value += n; lock.unlock() }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - Raw file-descriptor connection (usbmuxd tunnel)

public final class SocketConnection: FramedConnection, @unchecked Sendable {
    public var onMessage: (@Sendable (Message) -> Void)?
    public var onClose: (@Sendable (Error?) -> Void)?

    private let fd: Int32
    private let readQueue = DispatchQueue(label: "extdisplay.socket.read", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "extdisplay.socket.write", qos: .userInteractive)
    private var readSource: DispatchSourceRead?
    private var decoder = FrameDecoder()
    private let pending = PendingCounter()
    private let stateLock = NSLock()
    private var closed = false

    public var pendingBytes: Int { pending.current }

    /// Takes ownership of a connected, blocking stream socket.
    public init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var buf: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
    }

    public func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        readSource = source
        source.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n <= 0 {
            let err: Error? = n < 0 ? POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) : nil
            finish(err)
            return
        }
        do {
            let messages = try decoder.append(Data(chunk[0..<n]))
            for m in messages { onMessage?(m) }
        } catch {
            finish(error)
        }
    }

    public func send(_ message: Message) {
        let frame = FrameEncoder.encode(message)
        pending.add(frame.count)
        writeQueue.async { [weak self] in
            guard let self else { return }
            defer { self.pending.add(-frame.count) }
            if self.isClosed { return }
            let ok = frame.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let w = Darwin.write(self.fd, raw.baseAddress! + offset, raw.count - offset)
                    if w < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += w
                }
                return true
            }
            if !ok { self.readQueue.async { self.finish(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE)) } }
        }
    }

    private var isClosed: Bool { stateLock.lock(); defer { stateLock.unlock() }; return closed }

    private func finish(_ error: Error?) {
        stateLock.lock()
        if closed { stateLock.unlock(); return }
        closed = true
        stateLock.unlock()
        readSource?.cancel()
        readSource = nil
        onClose?(error)
    }

    public func close() {
        readQueue.async { self.finish(nil) }
    }
}

// MARK: - Network.framework connection (iOS listener side, and Wi-Fi on the Mac)

public final class NWFramedConnection: FramedConnection, @unchecked Sendable {
    public var onMessage: (@Sendable (Message) -> Void)?
    public var onClose: (@Sendable (Error?) -> Void)?
    /// Called once the connection reaches `.ready`.
    public var onReady: (@Sendable () -> Void)?

    public let connection: NWConnection
    private let queue = DispatchQueue(label: "extdisplay.nw", qos: .userInteractive)
    private var decoder = FrameDecoder()
    private let pending = PendingCounter()
    private var startedReceive = false
    private var closed = false

    public var pendingBytes: Int { pending.current }

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 6
        tcp.connectionTimeout = 15
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        params.includePeerToPeer = true
        return params
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.startedReceive, !self.closed else { return }
                self.startedReceive = true
                self.onReady?()
                self.receive()
            case .failed(let error):
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                do {
                    for m in try self.decoder.append(data) { self.onMessage?(m) }
                } catch {
                    self.finish(error)
                    return
                }
            }
            if let error {
                self.finish(error)
            } else if isComplete {
                self.finish(nil)
            } else {
                self.receive()
            }
        }
    }

    public func send(_ message: Message) {
        let frame = FrameEncoder.encode(message)
        pending.add(frame.count)
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.closed else {
                self.pending.add(-frame.count)
                return
            }
            self.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                self?.pending.add(-frame.count)
                if let error {
                    self?.finish(error)
                }
            })
        }
    }

    private func finish(_ error: Error?) {
        queue.async {
            if self.closed { return }
            self.closed = true
            self.connection.cancel()
            self.onClose?(error)
        }
    }

    public func close() {
        finish(nil)
    }
}

