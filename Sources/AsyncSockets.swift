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

#if BINARY_SPEC_IS_A_MODULE
    import CocoaAsyncSocket
    import Result
#endif

public final class BinarySocket: GCDAsyncSocketDelegate {
    private let parser: BinaryParser
    private let encoder: BinaryEncoder
    private let handlerQueue: dispatch_queue_t
    private let handler: Result<[BinaryData], NSError> -> ()
    private let socket: GCDAsyncSocket
    private var writeCallbackQueue: dispatch_queue_t
    private var writeCallbacks: [Int: NSError? -> ()] = [:]
    private var nextWriteCallbackKey: Int = 0
    private let dataBuffer = NSMutableData()

    public init(spec: BinarySpec,
                handlerQueue: dispatch_queue_t,
                handler: Result<[BinaryData], NSError> -> ()) {
        parser = BinaryParser(spec)
        encoder = BinaryEncoder(spec)
        self.handlerQueue = handlerQueue
        self.handler = handler
        socket = GCDAsyncSocket()
        writeCallbackQueue = dispatch_queue_create("WriteCallbackLock", DISPATCH_QUEUE_SERIAL)
    }

    public func connect(address: SocketAddress, timeout: NSTimeInterval = 2.5) {
        let delegateQueue = dispatch_queue_create("Socket-\(address)", DISPATCH_QUEUE_CONCURRENT)
        socket.setDelegate(self, delegateQueue: delegateQueue)
        try! socket.connectToAddress(address.toNSData(), withTimeout: timeout)
        socket.readDataWithTimeout(-1, tag: -1)
    }

    public func disconnect() {
        socket.disconnect()
    }

    public var isDisconnected: Bool {
        return socket.isDisconnected
    }

    @objc public func socketDidDisconnect(sock: GCDAsyncSocket!, withError err: NSError!) {
        let e = err ?? NSError(domain: GCDAsyncSocketErrorDomain,
                               code: GCDAsyncSocketError.OtherError.rawValue,
                               userInfo: nil)
        let h = self.handler
        var writeCallbacks: [Int: NSError? -> ()] = [:]
        dispatch_sync(writeCallbackQueue) {
            swap(&writeCallbacks, &self.writeCallbacks)
        }
        dispatch_async(handlerQueue) {
            h(.Failure(e))
            for callback in writeCallbacks.values {
                callback(e)
            }
        }
    }

    @objc public func socket(sock: GCDAsyncSocket!, didReadData data: NSData!, withTag tag: Int) {
        parser.supply(data)
        let content = parser.parseAll()
        if !content.isEmpty {
            let h = self.handler
            dispatch_async(handlerQueue) {
                h(.Success(content))
            }
        }

        if tag == -1 {
            sock.readDataWithTimeout(-1, tag: -1)
        }
    }

    public func write(data: BinaryDataConvertible, timeout: NSTimeInterval = -1, callback: (NSError? -> ())? = nil) {
        guard !socket.isDisconnected else {
            callback?(NSError(domain: GCDAsyncSocketErrorDomain, code: GCDAsyncSocketError.ClosedError.rawValue, userInfo: nil))
            return
        }

        var key: Int!
        dispatch_sync(writeCallbackQueue) {
            key = self.nextWriteCallbackKey
            self.nextWriteCallbackKey = key &+ 1
            self.writeCallbacks[key] = callback
        }
        let encodedData = encoder.encode(data.toBinaryData())
        socket.writeData(encodedData, withTimeout: timeout, tag: key)
    }

    @objc public func socket(sock: GCDAsyncSocket!, didWriteDataWithTag tag: Int) {
        var callback: (NSError? -> ())?
        dispatch_sync(writeCallbackQueue) {
            callback = self.writeCallbacks.removeValueForKey(tag)
        }
        if let callback = callback {
            dispatch_async(handlerQueue) {
                callback(nil)
            }
        }
    }
}
