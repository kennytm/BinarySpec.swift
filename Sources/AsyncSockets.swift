//
//  AsyncSockets.swift
//  BinarySpec
//
//  Created by kennytm on 15-12-09.
//  Copyright © 2015 kennytm. All rights reserved.
//

import Dispatch

// MARK: Addressing

extension sockaddr_storage {
    /// Creates a `sockaddr` structure from the string representation.
    public init(IPv4 host: String, port: UInt16) {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(sizeofValue(address))
        address.sin_addr.s_addr = inet_addr(host)
        address.sin_port = port.bigEndian
        self.init()
        memcpy(&self, &address, sizeofValue(address))
    }
}

// MARK: - GCD Utils

private let QueueOwnerKey: NSString = "BinarySpec.DebugQueueOwner"
private let QueueOwnerKeyPtr = UnsafePointer<Void>(Unmanaged.passUnretained(QueueOwnerKey).toOpaque())

private func serialize(queue: dispatch_queue_t, name: String) -> dispatch_queue_t {
    let serialQueue = dispatch_queue_create(name, DISPATCH_QUEUE_SERIAL)
    dispatch_set_target_queue(serialQueue, queue)
    return serialQueue
}

public protocol QueueOwnerType {
    var queue: dispatch_queue_t { get }
}

extension QueueOwnerType {
    private func async(closure: Self -> ()) {
        dispatch_async(queue) {
            closure(self)
        }
    }

    private func isOwnerQueue() -> Bool {
        let queuePtr = UnsafeMutablePointer<Void>(Unmanaged.passUnretained(queue).toOpaque())
        let currentQueuePtr = dispatch_get_specific(QueueOwnerKeyPtr)
        return queuePtr == currentQueuePtr
    }

    private func assertOwnerQueue() {
        assert(isOwnerQueue())
    }

    private func sync<T>(closure: Self -> T) -> T {
        if isOwnerQueue() {
            return closure(self)
        } else {
            var result: T?
            dispatch_sync(queue) {
                result = closure(self)
            }
            return result!
        }
    }
}

public class QueueOwner: QueueOwnerType {
    public let queue: dispatch_queue_t

    private init(_ queue: dispatch_queue_t) {
        self.queue = queue
        let queuePtr = UnsafeMutablePointer<Void>(Unmanaged.passUnretained(queue).toOpaque())
        dispatch_queue_set_specific(queue, QueueOwnerKeyPtr, queuePtr, nil)
    }
}

// MARK: - Result

public enum SocketResult<T> {
    case Ok(T)
    case POSIXError(errno_t)
    case Closed
}

// MARK: - Connection

private class ConnectionImpl: QueueOwner {
    private var channel: dispatch_io_t?
    private weak var parent: SocketConnection?

    private init(io: dispatch_io_t, parent: SocketConnection) {
        super.init(serialize(parent.queue, name: "ConnectionImpl"))
        channel = io
        self.parent = parent
    }

    deinit {
        dispose()
    }

    private func dispose() {
        if let io = channel {
            dispatch_io_close(io, DISPATCH_IO_STOP)
            channel = nil
        }
    }

    private func readOnce() {
        assertOwnerQueue()

        guard let parent = parent else { return }
        guard let channel = channel else { return }

        dispatch_io_read(channel, 0, Int.max, parent.queue, parent.informRead)
    }

    private func writeOnce(data: dispatch_data_t, completion: (errno_t -> ())?) {
        assertOwnerQueue()

        guard let parent = parent else { return }
        guard let channel = channel else { return }

        dispatch_io_write(channel, 0, data, parent.queue) { done, _, err in
            if done {
                completion?(err)
            }
        }
    }
}

private class ReadHandler: QueueOwner {
    private var handler: (SocketResult<dispatch_data_t> -> ())?

    private func release() -> (SocketResult<dispatch_data_t> -> ())? {
        return sync {
            let oldHandler = $0.handler
            $0.handler = nil
            return oldHandler
        }
    }

    private func store(newHandler: (SocketResult<dispatch_data_t> -> ())?) {
        async {
            $0.handler = newHandler
        }
    }

    private func load() -> (SocketResult<dispatch_data_t> -> ())? {
        return sync {
            return $0.handler
        }
    }
}

/// Wraps a full-duplex TCP connection driven by GCD (dispatch_io).
public final class SocketConnection: QueueOwner {
    private var impl: ConnectionImpl!
    private let readHandler: ReadHandler

    private init(fd: dispatch_fd_t, queue: dispatch_queue_t) {
        readHandler = ReadHandler(serialize(queue, name: "ReadHandler"))
        super.init(queue)

        let io = dispatch_io_create(DISPATCH_IO_STREAM, fd, queue) { _ in
            Darwin.close(fd)

            guard let handler = self.readHandler.release() else { return }

            var errorCode = errno_t(0)
            var len = socklen_t(sizeofValue(errorCode))
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &errorCode, &len)
            handler(.POSIXError(errorCode))
        }
        dispatch_io_set_low_water(io, 1)

        impl = ConnectionImpl(io: io, parent: self)
    }

    /// Starts the `recv()` loop. The loop will end only after the socket is disconnected.
    public func startRecvLoop(reader: SocketResult<dispatch_data_t> -> ()) {
        readHandler.store(reader)
        impl.async {
            $0.readOnce()
        }
    }

    private func informRead(done: Bool, _ data: dispatch_data_t?, _ error: errno_t) {
        assertOwnerQueue()

        let handler = readHandler.load()

        if let data = data {
            if data.isEmpty && done {
                handler?(.Closed)
            } else {
                handler?(.Ok(data))
                impl.async {
                    $0.readOnce()
                }
                return
            }
        }
        if error != 0 {
            handler?(.POSIXError(error))
        }

        readHandler.store(nil)
        close()
    }

    /// Sends data to the peer.
    public func send(data: dispatch_data_t, completion: (errno_t -> ())? = nil) {
        impl.async {
            $0.writeOnce(data, completion: completion)
        }
    }

    public func close() {
        impl.async {
            $0.dispose()
        }
    }
}

// MARK: - Socket

public typealias ConnectionHandler = SocketResult<SocketConnection> -> ()

private class SocketImpl: QueueOwner {
    private var sck: dispatch_fd_t
    private var connectSource: dispatch_source_t? = nil
    private var timeoutSource: dispatch_source_t? = nil
    private weak var parent: Socket?

    private init(sck: dispatch_fd_t, parent: Socket) {
        self.sck = sck
        self.parent = parent
        super.init(serialize(parent.queue, name: "SocketImpl"))
    }

    private func dispose() {
        if let src = connectSource {
            dispatch_source_cancel(src)
            connectSource = nil
        }
        if let src = timeoutSource {
            dispatch_source_cancel(src)
            timeoutSource = nil
        }
        if sck >= 0 {
            close(sck)
            sck = -1
        }
    }

    deinit {
        dispose()
    }

    private func tryConnect(address: sockaddr_storage, queue: dispatch_queue_t) -> Bool {
        assertOwnerQueue()

        var addressStorage = address
        let connectResult = withUnsafePointer(&addressStorage) {
            connect(sck, UnsafePointer($0), socklen_t($0.memory.ss_len))
        }

        if connectResult == 0 {
            dispatch_async(queue) {
                self.parent?.informClientConnected()
            }
            return false
        } else {
            switch errno {
            case EINPROGRESS, EWOULDBLOCK:
                return true
            case let e:
                dispatch_async(queue) {
                    self.parent?.informError(e)
                }
                return false
            }
        }
    }

    private func addTimeoutTimer(queue: dispatch_queue_t, timeout: dispatch_time_t) {
        guard timeout != DISPATCH_TIME_FOREVER else { return }

        assertOwnerQueue()

        let timeoutSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue)
        timeoutSource = timeoutSrc
        dispatch_source_set_timer(timeoutSrc, timeout, DISPATCH_TIME_FOREVER, 0)
        dispatch_source_set_event_handler(timeoutSrc) { [weak self] _ in
            self?.parent?.informError(ETIMEDOUT)
        }
        dispatch_resume(timeoutSrc)
    }

    private func addConnectListener(queue: dispatch_queue_t) {
        assertOwnerQueue()

        let src = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, UInt(sck), 0, queue)
        connectSource = src
        dispatch_source_set_event_handler(src) { [weak self] _ in
            guard let parent = self?.parent else { return }

            let socket = dispatch_fd_t(dispatch_source_get_handle(src))
            var errorNumber = errno_t(0)
            var errorNumberSize = socklen_t(sizeofValue(errorNumber))
            guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &errorNumber, &errorNumberSize) >= 0 else {
                parent.informError(errno)
                return
            }
            if errorNumber == 0 {
                parent.informClientConnected()
            } else {
                parent.informError(errorNumber)
            }
        }
        dispatch_resume(src)
    }

    private func connectTo(address: sockaddr_storage, queue: dispatch_queue_t, timeout: dispatch_time_t) {
        assertOwnerQueue()

        guard tryConnect(address, queue: queue) else { return }

        addTimeoutTimer(queue, timeout: timeout)
        addConnectListener(queue)
    }

    private func releaseSocketToConnection() {
        assertOwnerQueue()

        let oldSocket = sck
        sck = -1
        dispose()

        parent?.async {
            $0.addConnectionFromRawSocket(oldSocket)
        }
    }
}

/// A socket. Suitable for a TCP client, TCP server or UDP client (communicating with a single peer).
public class Socket: QueueOwner {
    private var impl: SocketImpl!
    private let connectionHandler: ConnectionHandler

    private init(family: sa_family_t, queue: dispatch_queue_t, handler: ConnectionHandler) {
        connectionHandler = handler
        super.init(queue)

        let sck = BinarySpec_createNonBlockingSocket(Int32(family), SOCK_STREAM)
        assert(sck >= 0)
        impl = SocketImpl(sck: sck, parent: self)
    }

    /// Creates a connected TCP client.
    ///
    /// - Parameters:
    ///   - address: 
    ///     Pointer to a `sockaddr_storage` structure that contains the address of the peer. The
    ///     `ss_family` and `ss_len` fields must be correctly filled in.
    ///   - queue:
    ///     The queue that waits on the socket events.
    ///   - timeout:
    ///     The time point which the connection attempt will be canceled.
    ///   - handler:
    ///     A handler that will be called once when the connection is established or failed.
    public convenience init(connect address: sockaddr_storage,
        queue: dispatch_queue_t,
        timeout: dispatch_time_t = DISPATCH_TIME_FOREVER,
        handler: ConnectionHandler) {

            self.init(family: address.ss_family, queue: queue, handler: handler)
            impl.async {
                $0.connectTo(address, queue: queue, timeout: timeout)
            }
    }

    private func informClientConnected() {
        assertOwnerQueue()
        impl.async {
            $0.releaseSocketToConnection()
        }
    }

    private func informError(errorNumber: errno_t) {
        assertOwnerQueue()
        connectionHandler(.POSIXError(errorNumber))

        impl.async {
            $0.dispose()
        }
    }

    private func addConnectionFromRawSocket(fd: dispatch_fd_t) {
        assertOwnerQueue()
        let connection = SocketConnection(fd: fd, queue: queue)
        connectionHandler(.Ok(connection))
    }

    /// Closes the socket. This makes the socket no longer able to listen to incoming peers. 
    /// Established connections may still be intact after this call, however.
    public func close() {
        impl.async {
            $0.dispose()
        }
        dispatch_async(queue) { [weak self] _ in
            self?.connectionHandler(.Closed)
        }
    }

    deinit {
        close()
    }
}
