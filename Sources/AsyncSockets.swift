/*

Copyright 2015 HiHex Ltd.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in
compliance with the License. You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is
distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
implied. See the License for the specific language governing permissions and limitations under the
License.

*/

import Dispatch
import Foundation

// MARK: - Read stream

public class AbstractDispatchReader {
    private let source: dispatch_source_t
    private let readQueue: dispatch_queue_t
    private let handlerQueue: dispatch_queue_t
    private let canRunHandlerDirectly: Bool

    /// Constructs a new reader which parses data from a file descriptor (like a file or a socket).
    ///
    /// - Parameters:
    ///   - parser:
    ///     The parser which decodes the data.
    ///
    ///   - fd:
    ///     A *non-blocking* file-descriptor to receive the data. The file must be open as long as
    ///     this instance is still alive (not `dispose()`d).
    ///
    ///   - readQueue:
    ///     The queue that waits for data to be available, and performs the reading operation (The
    ///     actual operation will be done on a serial subqueue of this queue). This is usually the
    ///     same queue used to open the file/socket.
    ///
    ///   - handlerQueue:
    ///     The queue that executes the handler. This is usually the "main" thread which analyze the
    ///     received data.
    ///
    ///   - handler:
    ///     The closure that parses the decoded data. If possible, multiple pieces of packets will
    ///     be emitted together.
    ///
    ///     If the end-of-file is reached or the socket is closed orderly by the peer, the handler
    ///     will receive a POSIX-domain error `ESHUTDOWN`. If the reader is disposed manually, it
    ///     will receive `ECANCELED`.
    private init(fd: dispatch_fd_t, readQueue: dispatch_queue_t, handlerQueue: dispatch_queue_t) {
        self.readQueue = dispatch_queue_create("AbstractDispatchReader", DISPATCH_QUEUE_SERIAL)
        dispatch_set_target_queue(self.readQueue, readQueue)
        self.handlerQueue = handlerQueue
        self.canRunHandlerDirectly = readQueue === handlerQueue
        source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, UInt(fd), 0, self.readQueue)
        dispatch_source_set_event_handler(source) { [weak self] in
            self?.readData()
        }
        dispatch_resume(source)
    }

    deinit {
        dispose()
    }

    /// Stops the reading source. After calling this, the handler will receive `ECANCELED`.
    public func dispose() {
        dispose(ECANCELED)
    }

    /// Checks whether the reader has been disposed (canceled).
    public var disposed: Bool {
        return dispatch_source_testcancel(source) != 0
    }

    private func dispose(errorCode: errno_t) {
        guard !disposed else { return }

        dispatch_source_cancel(source)
        dispatch_async(handlerQueue) { [weak self] _ in
            self?.handleError(errorCode)
        }
    }

    private func readData() {
        let fd = dispatch_fd_t(dispatch_source_get_handle(source))
        let available = Int(dispatch_source_get_data(source))

        handleDataAvailable(fd, available)
    }

    private func handleError(error: errno_t) {
        fatalError("abstract")
    }

    private func handleDataAvailable(fd: dispatch_fd_t, _ available: Int) {
        fatalError("abstract")
    }

    private final func invokeHandlerDirectly<T>(data: T, callback: T -> ()) {
        if canRunHandlerDirectly {
            callback(data)
        } else {
            dispatch_async(handlerQueue) {
                callback(data)
            }
        }
    }
}


/// An asynchronous file/socket reader, and generates packets of `BinaryData` from the raw bytes.
///
/// This class is a thin wrapper of a `dispatch_source_t(DISPATCH_SOURCE_TYPE_READ)`.
public final class BinaryReader: AbstractDispatchReader {
    private let parser: BinaryParser
    private let handler: Result<[BinaryData], NSError> -> ()

    /// Constructs a new reader which parses data from a file descriptor (like a file or a socket).
    ///
    /// - Parameters:
    ///   - parser:
    ///     The parser which decodes the data.
    ///
    ///   - fd: 
    ///     A *non-blocking* file-descriptor to receive the data. The file must be open as long as
    ///     this instance is still alive (not `dispose()`d).
    ///
    ///   - readQueue: 
    ///     The queue that waits for data to be available, and performs the reading operation (The
    ///     actual operation will be done on a serial subqueue of this queue). This is usually the
    ///     same queue used to open the file/socket.
    ///
    ///   - handlerQueue:
    ///     The queue that executes the handler. This is usually the "main" thread which analyze the 
    ///     received data.
    ///
    ///   - handler: 
    ///     The closure that parses the decoded data. If possible, multiple pieces of packets will
    ///     be emitted together.
    ///
    ///     If the end-of-file is reached or the socket is closed orderly by the peer, the handler
    ///     will receive a POSIX-domain error `ESHUTDOWN`. If the reader is disposed manually, it
    ///     will receive `ECANCELED`.
    public init(parser: BinaryParser, fd: dispatch_fd_t, readQueue: dispatch_queue_t, handlerQueue: dispatch_queue_t, handler: Result<[BinaryData], NSError> -> ()) {
        self.parser = parser
        self.handler = handler
        super.init(fd: fd, readQueue: readQueue, handlerQueue: handlerQueue)
    }

    private override func handleError(error: errno_t) {
        handler(.Failure(NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: nil)))
    }

    private override func handleDataAvailable(fd: dispatch_fd_t, _ available: Int) {
        let buffer = malloc(available)
        let actual = read(fd, buffer, available)

        guard actual > 0 else {
            free(buffer)
            let errorCode = actual == 0 ? ESHUTDOWN : errno
            dispose(errorCode)
            return
        }

        let data = dispatch_data_create(buffer, actual, readQueue, _dispatch_data_destructor_free)
        parser.supply(data)
        let result = parser.parseAll()
        guard !result.isEmpty else { return }

        invokeHandlerDirectly(.Success(result), callback: handler)
    }
}


/// The synchronous version of BinaryReader.
public final class SyncBinaryReader {
    private class Buffer {
        var data = [BinaryData]()
        var error: NSError? = nil
        let semaphore = dispatch_semaphore_create(0)

        func handler(newResult: Result<[BinaryData], NSError>) {
            assert(error == nil || newResult.error != nil, "Should not receive data after an error is sent")
            switch newResult {
            case let .Success(b):
                data += b
            case let .Failure(e):
                error = e
            }
            dispatch_semaphore_signal(semaphore)
        }

        func get() -> Result<BinaryData, NSError>? {
            if !data.isEmpty {
                return .Success(data.removeFirst())
            } else if let err = error {
                return .Failure(err)
            } else {
                return nil
            }
        }
    }

    private var reader: BinaryReader
    private var buffer = Buffer()

    /// Creates a synchronous reader.
    ///
    /// - Parameters:
    ///   - parser:
    ///     The parser which decodes the data.
    ///
    ///   - fd:
    ///     A *non-blocking* file-descriptor to receive the data. The file must be open as long as
    ///     this instance is still alive (not `dispose()`d).
    ///
    ///   - queue:
    ///     The queue that waits for data to be available, and performs the reading operation. This
    ///     queue should be a background queue, i.e. *not* the one that calls `read()`.
    public init(parser: BinaryParser, fd: dispatch_fd_t, queue: dispatch_queue_t) {
        reader = BinaryReader(parser: parser, fd: fd, readQueue: queue, handlerQueue: queue, handler: buffer.handler)
    }

    public func dispose() {
        reader.dispose()
    }

    /// Reads one packet from the reader.
    ///
    /// This method **must not** run on the queue given to this reader, as it will lead to deadlock.
    public func syncRead(timeout timeout: dispatch_time_t = DISPATCH_TIME_FOREVER) -> Result<BinaryData, NSError> {
        // Pump out cached data if possible.
        var fastResult: Result<BinaryData, NSError>?
        dispatch_sync(reader.readQueue) {
            fastResult = self.buffer.get()
        }
        if let a = fastResult {
            return a
        }

        // Before actually reading the data, make sure the channel is still open.
        guard !reader.disposed else {
            return .Failure(NSError(domain: NSPOSIXErrorDomain, code: Int(ECANCELED), userInfo: nil))
        }

        let waitResult = dispatch_semaphore_wait(buffer.semaphore, timeout)
        guard waitResult == 0 else {
            return .Failure(NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT), userInfo: nil))
        }

        var result: Result<BinaryData, NSError>!
        dispatch_sync(reader.readQueue) {
            result = self.buffer.get()
        }
        return result
    }
}

// MARK: - Write stream

typealias SyncBinaryWriter = BinaryWriter

/// Wrapper around an asynchronous file writer. This class is a thin wrapper of a 
/// `dispatch_source_t(DISPATCH_SOURCE_TYPE_WRITE)`.
public final class BinaryWriter {
    private struct DataWrittenHandler {
        var offset: Int
        var handler: NSError? -> ()
    }

    private var source: dispatch_source_t
    private let writeQueue: dispatch_queue_t
    private var remainingData = dispatch_data_empty
    private var lastError: NSError? = nil
    private var suspendCount: Int = 0
    private var dataWrittenHandlers = [DataWrittenHandler]()
    private let encoder: BinaryEncoder?

    /// Constructs a new writer which writer data to a file descriptor (like a file or a socket).
    ///
    /// - Parameters:
    ///   - encoder:
    ///     The encoder to use if you want to write BinaryData.
    ///
    ///   - fd:
    ///     A *non-blocking* file-descriptor to send the data. The file must be open as long as this
    ///     instance is still alive (not `dispose()`d).
    ///
    ///   - writeQueue:
    ///     The queue that waits for the file ready to receive data, and performs the writing 
    ///     operation. (The actual operation will be done on a serial subqueue of this queue). This
    ///     is usually the same queue used to open the file/socket.
    public init(encoder: BinaryEncoder?, fd: dispatch_fd_t, writeQueue: dispatch_queue_t) {
        self.writeQueue = dispatch_queue_create("BinaryWriter", DISPATCH_QUEUE_SERIAL)
        self.encoder = encoder
        dispatch_set_target_queue(self.writeQueue, writeQueue)
        source = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, UInt(fd), 0, writeQueue)
        dispatch_source_set_event_handler(source) { [weak self] in
            self?.flush()
        }
        dispatch_resume(source)
    }

    deinit {
        asyncDispose()
    }

    public func dispose() {
        dispatch_async(writeQueue) {
            self.asyncDispose()
        }
    }

    private func resumeSource() {
        let repeatCount = suspendCount
        suspendCount = 0
        for _ in 0 ..< repeatCount {
            dispatch_resume(source)
        }
    }

    private func asyncDispose() {
        resumeSource()
        dispatch_source_cancel(source)

        remainingData = dispatch_data_empty
        lastError = NSError(domain: NSPOSIXErrorDomain, code: Int(ECANCELED), userInfo: nil)
        for h in dataWrittenHandlers {
            h.handler(lastError)
        }
        dataWrittenHandlers.removeAll()
    }

    private func flush() {
        guard suspendCount == 0 else { return }

        let totalLength = remainingData.count
        guard totalLength > 0 else { return }

        let fd = dispatch_fd_t(dispatch_source_get_handle(source))
        let bufferSize = min(Int(dispatch_source_get_data(source)), totalLength)

        var dataToWrite = dispatch_data_create_subrange(remainingData, 0, bufferSize)!
        let bytesToWrite = linearize(&dataToWrite)
        let totalBytesWritten = Darwin.write(fd, bytesToWrite.baseAddress, bytesToWrite.count)

        let remainingLength: Int
        if totalBytesWritten >= 0 {
            remainingLength = totalLength - totalBytesWritten
            remainingData = dispatch_data_create_subrange(remainingData, totalBytesWritten, remainingLength)
        } else {
            remainingLength = totalLength
            switch errno {
            case EAGAIN, EWOULDBLOCK, EINPROGRESS:
                break
            case let e:
                lastError = NSError(domain: NSPOSIXErrorDomain, code: Int(e), userInfo: nil)
            }
        }

        if remainingLength <= 0 {
            suspendCount += 1
            dispatch_suspend(source)
        }

        var newHandlers = [DataWrittenHandler]()
        for handler in dataWrittenHandlers {
            if handler.offset <= totalBytesWritten {
                handler.handler(nil)
            } else if lastError != nil {
                handler.handler(lastError)
            } else {
                let newOffset = handler.offset - totalBytesWritten
                newHandlers.append(DataWrittenHandler(offset: newOffset, handler: handler.handler))
            }
        }
        dataWrittenHandlers = newHandlers
    }

    private func asyncWrite(data: dispatch_data_t, callback: (NSError? -> ())?) {
        guard data.count > 0 && lastError == nil else {
            callback?(lastError)
            return
        }

        remainingData = dispatch_data_create_concat(remainingData, data)
        if let callback = callback {
            let offset = dispatch_data_get_size(remainingData)
            dataWrittenHandlers.append(DataWrittenHandler(offset: offset, handler: callback))
        }
        resumeSource()
    }

    /// Asynchronously writes data to the file. The data will be queued until the file is ready to 
    /// accept more data.
    public func write(data: dispatch_data_t, callback: (NSError? -> ())? = nil) {
        dispatch_async(writeQueue) {
            self.asyncWrite(data, callback: callback)
        }
    }

    /// Asynchronously writes data to the file. If you call this method, the encoder argument in the
    /// constructor must not be nil.
    public func write(data: BinaryData, callback: (NSError? -> ())? = nil) {
        write(encoder!.encode(data), callback: callback)
    }

    /// Synchronously writes data to the file.
    public func syncWrite(data: dispatch_data_t, timeout: dispatch_time_t = DISPATCH_TIME_FOREVER) -> NSError? {
        let semaphore = dispatch_semaphore_create(0)

        var result: NSError? = nil

        dispatch_sync(writeQueue) {
            self.asyncWrite(data) {
                result = $0
                dispatch_semaphore_signal(semaphore)
            }
        }

        guard dispatch_semaphore_wait(semaphore, timeout) == 0 else {
            return NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT), userInfo: nil)
        }

        return result
    }

    /// Synchronously writes data to the file. If you call this method, the encoder argument in the
    /// constructor must not be nil.
    public func syncWrite(data: BinaryData, timeout: dispatch_time_t = DISPATCH_TIME_FOREVER) -> NSError? {
        return syncWrite(encoder!.encode(data), timeout: timeout)
    }
}

// MARK: - Accepted clients stream

/// A stream that asynchronously reports accepted clients of a bound socket.
public final class SocketAcceptor: AbstractDispatchReader {
    private let handler: Result<(dispatch_fd_t, SocketAddress?), NSError> -> ()
    private var counter = 0

    public init(fd: dispatch_fd_t, acceptQueue: dispatch_queue_t, handlerQueue: dispatch_queue_t, handler: Result<(dispatch_fd_t, SocketAddress?), NSError> -> ()) {
        self.handler = handler
        super.init(fd: fd, readQueue: acceptQueue, handlerQueue: handlerQueue)
    }

    private override func handleError(error: errno_t) {
        handler(.Failure(NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: nil)))
    }

    private override func handleDataAvailable(fd: dispatch_fd_t, _: Int) {
        counter += 1
        let (addr, client) = SocketAddress.receive { accept(fd, $0, $1) }
        let result: Result<(dispatch_fd_t, SocketAddress?), NSError>
        if client >= 0 {
            result = .Success((client, addr))
        } else {
            switch errno {
            case EAGAIN, EWOULDBLOCK, EINPROGRESS:
                return
            case let errorCode:
                result = .Failure(NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode), userInfo: nil))
            }
        }
        invokeHandlerDirectly(result, callback: handler)
    }
}
