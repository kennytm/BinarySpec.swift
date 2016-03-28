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

import XCTest
@testable import BinarySpec

class ReadTest: XCTestCase {
    func testRead() {
        let clientSocketQueue = dispatch_queue_create("ClientSocketQueue", DISPATCH_QUEUE_CONCURRENT)
        let clientHandlerQueue = dispatch_queue_create("ClientHandlerQueue", DISPATCH_QUEUE_CONCURRENT)

        let serverReadySemaphore = dispatch_semaphore_create(0)
        runReadServer(serverReadySemaphore, port: 40515)

        var reader: BinaryReader? = nil
        var readResult = [Result<[BinaryData], NSError>]()
        let expectation = expectationWithDescription("Everything read")

        dispatch_async(clientHandlerQueue) {
            let socket = BinarySpec_createNonBlockingSocket(AF_INET, SOCK_STREAM)
            defer { close(socket) }

            dispatch_semaphore_wait(serverReadySemaphore, DISPATCH_TIME_FOREVER)
            usleep(10_000)

            let address = IPAddress.localhost.withPort(40515)
            address.withSockaddr {
                connect(socket, $0, $1)
            }

            let readSemaphore = dispatch_semaphore_create(0)
            let parser = BinaryParser(BinarySpec(parse: ">%B(I)"))
            reader = BinaryReader(parser: parser, fd: socket, readQueue: clientSocketQueue, handlerQueue: clientHandlerQueue) { arg in
                readResult.append(arg)
                if case .Failure = arg {
                    dispatch_semaphore_signal(readSemaphore)
                }
            }

            dispatch_semaphore_wait(readSemaphore, DISPATCH_TIME_FOREVER)
            expectation.fulfill()
        }

        waitForExpectationsWithTimeout(2.0, handler: nil)

        XCTAssertEqual(readResult.count, 3)
        XCTAssertEqual(readResult[0], success: [.Seq([
            .Integer(9),
            .Seq([
                .Integer(0x0230445a),
                .Integer(0x1462e3f3),
                ]),
            ])])
        XCTAssertEqual(readResult[1], success: [.Seq([
            .Integer(6),
            .Seq([
                .Integer(0x185caa19)
                ])
            ])])
        XCTAssertEqual(readResult[2], error: NSError(domain: NSPOSIXErrorDomain, code: Int(ESHUTDOWN), userInfo: nil))
    }

    func testSyncRead() {
        let clientSocketQueue = dispatch_queue_create("ClientSocketQueue", DISPATCH_QUEUE_CONCURRENT)

        let serverReadySemaphore = dispatch_semaphore_create(0)
        runReadServer(serverReadySemaphore, port: 11204)

        let socket = BinarySpec_createNonBlockingSocket(AF_INET, SOCK_STREAM)
        defer { close(socket) }

        dispatch_semaphore_wait(serverReadySemaphore, DISPATCH_TIME_FOREVER)
        usleep(100_000)

        let address = IPAddress.localhost.withPort(11204)
        address.withSockaddr {
            connect(socket, $0, $1)
        }

        let parser = BinaryParser(BinarySpec(parse: ">%B(I)"))
        let reader = SyncBinaryReader(parser: parser, fd: socket, queue: clientSocketQueue)

        let res1 = reader.syncRead(timeout: dispatch_walltime(nil, Int64(800 * NSEC_PER_MSEC)))
        XCTAssertEqual(res1, success: .Seq([
            .Integer(9),
            .Seq([
                .Integer(0x0230445a),
                .Integer(0x1462e3f3),
                ]),
            ]))

        let res2 = reader.syncRead(timeout: dispatch_walltime(nil, Int64(800 * NSEC_PER_MSEC)))
        XCTAssertEqual(res2, success: .Seq([
            .Integer(6),
            .Seq([
                .Integer(0x185caa19)
                ])
            ]))

        let res3 = reader.syncRead(timeout: dispatch_walltime(nil, Int64(800 * NSEC_PER_MSEC)))
        XCTAssertEqual(res3, error: NSError(domain: NSPOSIXErrorDomain, code: Int(ESHUTDOWN), userInfo: nil))

        reader.dispose()
    }

    private func runReadServer(serverReadySemaphore: dispatch_semaphore_t, port: UInt16) {
        let serverQueue = dispatch_queue_create("ServerSocketQueue", DISPATCH_QUEUE_CONCURRENT)

        dispatch_async(serverQueue) {
            let sck = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(sck) }

            var zero: Int32 = 0
            var one: Int32 = 1

            setsockopt(sck, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(sizeofValue(one)))
            setsockopt(sck, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(sizeofValue(one)))

            let address = IPAddress.zero.withPort(port)
            address.withSockaddr {
                Darwin.bind(sck, $0, $1)
            }
            listen(sck, 5)

            dispatch_semaphore_signal(serverReadySemaphore)

            let client = accept(sck, nil, nil)
            defer { close(client) }

            let msg1: [UInt8] = [9, 0x02, 0x30, 0x44, 0x5a, 0x14, 0x62]
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(sizeofValue(one)))
            send(client, msg1, msg1.count, 0)
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &zero, socklen_t(sizeofValue(zero)))

            usleep(500_000)

            let msg2: [UInt8] = [0xe3, 0xf3, 0xb7, 6, 0x18, 0x5c, 0xaa]
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(sizeofValue(one)))
            send(client, msg2, msg2.count, 0)
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &zero, socklen_t(sizeofValue(zero)))

            usleep(500_000)

            let msg3: [UInt8] = [0x19, 0x55, 0x3c, 13, 0x12]
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(sizeofValue(one)))
            send(client, msg3, msg3.count, 0)
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &zero, socklen_t(sizeofValue(zero)))
            
            usleep(500_000)
            
            shutdown(client, SHUT_RDWR)
        }
    }
}

class WriteTest: XCTestCase {
    func testWrite() {
        let clientSocketQueue = dispatch_queue_create("ClientSocketQueue", DISPATCH_QUEUE_CONCURRENT)
        let waitQueue = dispatch_queue_create("Wait", DISPATCH_QUEUE_CONCURRENT)

        var lotsOfData = [UInt8](count: 67890, repeatedValue: 0)
        for i in lotsOfData.indices {
            lotsOfData[i] = UInt8(truncatingBitPattern: i &* i)
        }
        let binData = BinaryData.Seq([
            .Integer(UIntMax(lotsOfData.count)),
            .Bytes(dispatch_data_create(lotsOfData, lotsOfData.count, dispatch_get_main_queue()) { _ in }),
            ])

        let serverReadySemaphore = dispatch_semaphore_create(0)
        runWriteServer(serverReadySemaphore, port: 55016)

        var writer: BinaryWriter? = nil
        var reader: BinaryReader? = nil
        var writeCallbackCalled = false
        var readResult = BinaryData.Empty
        let expectation = expectationWithDescription("Everything written")

        defer {
            reader?.dispose()
            writer?.dispose()
        }

        dispatch_async(clientSocketQueue) {
            let socket = BinarySpec_createNonBlockingSocket(AF_INET, SOCK_STREAM)

            dispatch_semaphore_wait(serverReadySemaphore, DISPATCH_TIME_FOREVER)
            usleep(10_000)

            let address = IPAddress.localhost.withPort(55016)
            address.withSockaddr {
                connect(socket, $0, $1)
            }

            let dg = dispatch_group_create()

            let spec = BinarySpec(parse: "<%Is")
            let encoder = BinaryEncoder(spec)
            let parser = BinaryParser(spec)

            dispatch_group_enter(dg)
            writer = BinaryWriter(encoder: encoder, fd: socket, writeQueue: clientSocketQueue)
            reader = BinaryReader(parser: parser, fd: socket, readQueue: clientSocketQueue, handlerQueue: clientSocketQueue) { res in
                switch res {
                case let .Success(results):
                    precondition(readResult == BinaryData.Empty)
                    precondition(results.count == 1)
                    readResult = results[0]
                    dispatch_group_leave(dg)
                    close(socket)
                case let .Failure(e):
                    precondition([ECANCELED, ESHUTDOWN].contains(errno_t(e.code)))
                }
            }

            dispatch_group_enter(dg)
            writer!.write(binData) {
                precondition($0 == nil)
                dispatch_group_leave(dg)
            }

            dispatch_async(waitQueue) {
                dispatch_group_wait(dg, DISPATCH_TIME_FOREVER)
                expectation.fulfill()
            }
        }

        waitForExpectationsWithTimeout(2.0, handler: nil)

        XCTAssertEqual(readResult[0], BinaryData.Integer(UIntMax(lotsOfData.count)))
        var readData = readResult[1].bytes
        let readBytes = linearize(&readData)
        XCTAssertEqual(readBytes.count, lotsOfData.count)
        for (i, j) in zip(readBytes, lotsOfData) {
            XCTAssertEqual(i, j ^ 0x75)
        }
    }

    func testSyncWrite() {
        let clientSocketQueue = dispatch_queue_create("ClientSocketQueue", DISPATCH_QUEUE_CONCURRENT)
        let waitQueue = dispatch_queue_create("Wait", DISPATCH_QUEUE_CONCURRENT)

        var lotsOfData = [UInt8](count: 67890, repeatedValue: 0)
        for i in lotsOfData.indices {
            lotsOfData[i] = UInt8(truncatingBitPattern: i &* i)
        }
        let binData = BinaryData.Seq([
            .Integer(UIntMax(lotsOfData.count)),
            .Bytes(dispatch_data_create(lotsOfData, lotsOfData.count, dispatch_get_main_queue()) { _ in }),
            ])

        let serverReadySemaphore = dispatch_semaphore_create(0)
        runWriteServer(serverReadySemaphore, port: 39103)

        let socket = BinarySpec_createNonBlockingSocket(AF_INET, SOCK_STREAM)
        defer { close(socket) }

        dispatch_semaphore_wait(serverReadySemaphore, DISPATCH_TIME_FOREVER)
        usleep(100_000)

        let address = IPAddress.localhost.withPort(39103)
        address.withSockaddr {
            connect(socket, $0, $1)
        }

        let spec = BinarySpec(parse: "<%Is")
        let encoder = BinaryEncoder(spec)
        let parser = BinaryParser(spec)

        let writer = SyncBinaryWriter(encoder: encoder, fd: socket, writeQueue: clientSocketQueue)
        let reader = SyncBinaryReader(parser: parser, fd: socket, queue: clientSocketQueue)

        let writeErr = writer.syncWrite(binData)
        XCTAssertNil(writeErr)
        let res = reader.syncRead(timeout: dispatch_walltime(nil, Int64(1 * NSEC_PER_SEC)))
        let readResult = try! res.dematerialize()

        XCTAssertEqual(readResult[0], BinaryData.Integer(UIntMax(lotsOfData.count)))
        var readData = readResult[1].bytes
        let readBytes = linearize(&readData)
        XCTAssertEqual(readBytes.count, lotsOfData.count)
        for (i, j) in zip(readBytes, lotsOfData) {
            XCTAssertEqual(i, j ^ 0x75)
        }

        writer.dispose()
        reader.dispose()

    }

    private func runWriteServer(serverReadySemaphore: dispatch_semaphore_t, port: UInt16) {
        let serverQueue = dispatch_queue_create("ServerSocketQueue", DISPATCH_QUEUE_CONCURRENT)

        dispatch_async(serverQueue) {
            let sck = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(sck) }

            var zero: Int32 = 0
            var one: Int32 = 1

            setsockopt(sck, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(sizeofValue(one)))
            setsockopt(sck, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(sizeofValue(one)))

            let address = IPAddress.zero.withPort(port)
            address.withSockaddr {
                Darwin.bind(sck, $0, $1)
            }
            listen(sck, 5)

            dispatch_semaphore_signal(serverReadySemaphore)

            let client = accept(sck, nil, nil)
            defer { close(client) }

            var length32: UInt32 = 0
            withUnsafeMutablePointer(&length32) {
                recv(client, UnsafeMutablePointer($0), sizeofValue($0.memory), 0)
            }
            var length = Int(length32)
            send(client, &length32, sizeofValue(length32), 0)

            var buffer = [UInt8](count: 16384, repeatedValue: 0)
            while length > 0 {
                let m: Int = buffer.withUnsafeMutableBufferPointer { (inout ptr: UnsafeMutableBufferPointer<UInt8>) -> Int in
                    recv(client, UnsafeMutablePointer(ptr.baseAddress), ptr.count, 0)
                }
                guard m > 0 else { break }

                let mm = min(m, length)
                for i in buffer.startIndex ..< buffer.startIndex.advancedBy(mm) {
                    buffer[i] ^= 0x75
                }
                send(client, buffer, mm, 0)

                length -= mm
            }

            shutdown(client, SHUT_RDWR)
        }
    }

}

class AcceptTest: XCTestCase {
    func testAccept() {
        let serverQueue = dispatch_queue_create("AcceptServer", DISPATCH_QUEUE_CONCURRENT)
        let clientsQueue = dispatch_queue_create("AcceptClients", DISPATCH_QUEUE_CONCURRENT)
        let acceptResultQueue = dispatch_queue_create("AcceptResultSync", DISPATCH_QUEUE_SERIAL)

        var acceptor: SocketAcceptor?
        defer { acceptor?.dispose() }

        var acceptResults = [Result<(dispatch_fd_t, SocketAddress?), NSError>]()

        let expectation = expectationWithDescription("All clients connected")

        let server = BinarySpec_createNonBlockingSocket(AF_INET, SOCK_STREAM)
        IPAddress.zero.withPort(33015).withSockaddr { Darwin.bind(server, $0, $1) }
        listen(server, SOMAXCONN)

        dispatch_async(serverQueue) {
            acceptor = SocketAcceptor(fd: server, acceptQueue: serverQueue, handlerQueue: acceptResultQueue) { res in
                guard acceptResults.count < 100 else {
                    precondition(res.error != nil)
                    return
                }

                guard case let .Success(fd, _) = res else {
                    preconditionFailure("\(res)")
                }
                close(fd)

                acceptResults.append(res)
                if acceptResults.count == 100 {
                    expectation.fulfill()
                }
            }
        }


        dispatch_apply(100, clientsQueue) { i in
            while true {
                let client = socket(AF_INET, SOCK_STREAM, 0)
                defer { close(client) }

                let r = IPAddress.localhost.withPort(33015).withSockaddr { connect(client, $0, $1) }
                if r == 0 {
                    break
                }
            }
        }

        waitForExpectationsWithTimeout(2.0, handler: nil)

        for res in acceptResults {
            guard case let .Success(_, .Internet(host, _)?) = res else {
                XCTFail()
                continue
            }
            XCTAssertEqual(host, IPAddress.localhost)
        }
    }
}

/*

class TCPClientTest: XCTestCase {
    let serverQueue = dispatch_queue_create("testConnect-Server", DISPATCH_QUEUE_CONCURRENT)
    let clientQueue = dispatch_queue_create("testConnect-Client", DISPATCH_QUEUE_CONCURRENT)
    let port = UInt16(arc4random_uniform(65536 - 1024) + 1024)
    let dispatchGroup: dispatch_group_t! = dispatch_group_create()
    let serverReadySemaphore = dispatch_semaphore_create(0)
    var tcpClient: Socket? = nil
    var hasTearedDown = false

    private func runServer(serverActions: Int32 -> ())  {
        dispatch_group_enter(dispatchGroup)
        dispatch_async(serverQueue) {
            let sck = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_storage(IPv4: "0.0.0.0", port: self.port)
            withUnsafePointer(&address) {
                Darwin.bind(sck, UnsafePointer($0), socklen_t($0.memory.ss_len))
            }
            listen(sck, 5)

            dispatch_semaphore_signal(self.serverReadySemaphore)

            var clientAddress = sockaddr_storage()
            var clientAddressLength = socklen_t(sizeofValue(clientAddress))
            let client = withUnsafeMutablePointers(&clientAddress, &clientAddressLength) {
                accept(sck, UnsafeMutablePointer($0), $1)
            }

            serverActions(client)

            usleep(100_000)

            close(client)
            close(sck)

            dispatch_group_leave(self.dispatchGroup)
        }
    }

    private func runClient(clientActions: (SocketConnection, finish: () -> ()) -> ()) {
        dispatch_group_enter(dispatchGroup)
        dispatch_async(clientQueue) {
            dispatch_semaphore_wait(self.serverReadySemaphore, DISPATCH_TIME_FOREVER)
            let address = sockaddr_storage(IPv4: "127.0.0.1", port: self.port)
            self.tcpClient = Socket(connect: address, queue: self.clientQueue) {
                if case let .Ok(connection) = $0 {
                    clientActions(connection) {
                        dispatch_group_leave(self.dispatchGroup)
                    }
                } else {
                    if !self.hasTearedDown {
                        // ^ If we do an XCTFail() after the test has finished it will crash with 
                        //   'Parameter "test" must not be nil.'
                        XCTFail("\($0) port=\(self.port)")
                    }
                }
            }
        }
    }

    private func waitForCompletion() {
        let expectation = expectationWithDescription("Communication completed")
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)) {
            let res = dispatch_group_wait(self.dispatchGroup, dispatch_walltime(nil, Int64(3 * NSEC_PER_SEC)))
            if res == 0 {
                expectation.fulfill()
            }
        }
        waitForExpectationsWithTimeout(3.1, handler: nil)
    }

    override func tearDown() {
        hasTearedDown = true
        tcpClient?.close()
    }

    func testSimpleConnection() {
        runServer { _ in }
        runClient { $1() }
        waitForCompletion()
    }

    func testSimpleRead() {
        runServer { sck in
            let msg = [UInt8]("12345678901234567890!@#$%^&*()".utf8)
            send(sck, msg, msg.count, 0)
        }

        var connection: SocketConnection?
        defer { connection?.close() }

        runClient { conn, finish in
            connection = conn
            var packetID = 0
            conn.startRecvLoop { res in
                packetID += 1
                switch res {
                case let .Ok(data):
                    XCTAssertEqual(packetID, 1)
                    XCTAssertEqual(data, [UInt8]("12345678901234567890!@#$%^&*()".utf8))
                    break
                case .Closed:
                    XCTAssertEqual(packetID, 2)
                    finish()
                    break
                case .POSIXError:
                    XCTFail("\(res)")
                    break
                }
            }
        }

        waitForCompletion()
    }

    func ignored_testReadNoDelay() {
        runServer { sck in
            do {
                let msg = [UInt8]("123456".utf8)
                send(sck, msg, msg.count, 0)
            }

            // Force flush the socket.
            var yes: Int32 = 1
            setsockopt(sck, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(sizeofValue(yes)))

            do {
                let msg = [UInt8]("abcdefg".utf8)
                send(sck, msg, msg.count, 0)
            }
        }

        var connection: SocketConnection?
        defer { connection?.close() }

        runClient { conn, finish in
            connection = conn
            var packetID = 0
            conn.startRecvLoop { res in
                packetID += 1
                switch res {
                case let .Ok(data) where packetID == 1:
                    XCTAssertEqual(data, [UInt8]("123456".utf8))
                    break
                case let .Ok(data) where packetID == 2:
                    XCTAssertEqual(data, [UInt8]("abcdefg".utf8))
                    break
                case .Closed:
                    XCTAssertEqual(packetID, 3)
                    finish()
                    break
                default:
                    XCTFail("\(res)")
                    break
                }
            }
        }

        waitForCompletion()
    }

    func testSimpleWrite() {
        let rawData = [UInt8]("asdfghjkl\u{1a}\u{1a}\u{1a}".utf8)

        runServer { sck in
            let buffer = [UInt8](count: 64, repeatedValue: 0)
            let recvCount = recv(sck, UnsafeMutablePointer(buffer), buffer.count, 0)
            XCTAssertEqual(recvCount, 12)
            XCTAssertEqual(Array(buffer[0 ..< 12]), rawData)
        }

        var connection: SocketConnection?
        defer { connection?.close() }

        runClient { conn, finish in
            connection = conn
            let data = dispatch_data_create(rawData, rawData.count, dispatch_get_main_queue(), { _ in })
            conn.send(data) { err in
                XCTAssertEqual(err, 0)
                finish()
            }
        }

        waitForCompletion()
    }

    func testIntegrationWithBinarySpec() {
        let serverRecvSpec = BinarySpec.Seq([
            .Integer(.UInt32LE),
            .Integer(.UInt32LE)
            ])

        let clientRecvSpec = BinarySpec.Seq([
            .Integer(.UInt32LE),
            .Integer(.UInt32LE),
            .Integer(.UInt32LE),
            .Integer(.UInt32LE)
            ])

        runServer { sck in
            let parser = BinaryParser(serverRecvSpec)
            var recvData: BinaryData?
            while recvData == nil {
                switch parser.next() {
                case let .Ok(data):
                    recvData = data
                    break
                case let .Incomplete(count):
                    let buffer = [UInt8](count: count, repeatedValue: 0)
                    recv(sck, UnsafeMutablePointer(buffer), buffer.count, 0)
                    parser.supply(buffer)
                    break
                }
            }

            guard case let .Seq(seq)? = recvData else {
                XCTFail()
                return
            }
            guard case let .Integer(first) = seq[0] else {
                XCTFail()
                return
            }
            guard case let .Integer(second) = seq[1] else {
                XCTFail()
                return
            }

            let clientData = BinaryData.Seq([
                .Integer(first + second),
                .Integer(first - second),
                .Integer(first * second),
                .Integer(first / second),
                ])

            var encodedData = BinaryEncoder(clientRecvSpec).encode(clientData)
            let linearized = linearize(&encodedData)
            send(sck, linearized.baseAddress, linearized.count, 0)
        }

        var connection: SocketConnection?
        defer { connection?.close() }

        runClient { conn, finish in
            connection = conn
            let parser = BinaryParser(clientRecvSpec)

            conn.startRecvLoop { ev in
                guard case let .Ok(data) = ev else {
                    if case .POSIXError = ev {
                        XCTFail("\(ev)")
                    }
                    return
                }

                parser.supply(data)
                if case let .Ok(binaryData) = parser.next() {
                    let expected = BinaryData.Seq([
                        BinaryData.Integer(78 + 12),
                        BinaryData.Integer(78 - 12),
                        BinaryData.Integer(78 * 12),
                        BinaryData.Integer(78 / 12),
                        ])
                    XCTAssertEqual(binaryData, expected)
                    finish()
                }
            }

            let serverData = BinaryData.Seq([
                .Integer(78),
                .Integer(12)
                ])
            let encodedData = BinaryEncoder(serverRecvSpec).encode(serverData)
            conn.send(encodedData)
        }

        waitForCompletion()
    }

    func testConnectionReset() {
        runServer { sck in
            var lngr = linger(l_onoff: 1, l_linger: 0)
            setsockopt(sck, SOL_SOCKET, SO_LINGER, &lngr, socklen_t(sizeofValue(lngr)))
        }

        runClient { conn, finish in
            conn.startRecvLoop { ev in
                switch ev {
                case .Closed:
                    break
                case .POSIXError(ECONNRESET):
                    finish()
                    break
                default:
                    XCTFail("\(ev)")
                    break
                }
            }
        }

        waitForCompletion()
    }
}


class FailingSocketsTest: XCTestCase {
    func testConnectFailLocal() {
        let clientQueue = dispatch_queue_create("testConnect-Client", DISPATCH_QUEUE_CONCURRENT)

        let expectation = expectationWithDescription("Connection refused")
        let address = sockaddr_storage(IPv4: "127.0.0.1", port: 41948)

        var isTestCompleted = false
        let tcpClient = Socket(connect: address, queue: clientQueue) {
            switch $0 {
            case .POSIXError(ECONNREFUSED):
                expectation.fulfill()
                break
            default:
                if !isTestCompleted {
                    XCTFail("\($0)")
                }
                break
            }
        }

        waitForExpectationsWithTimeout(3.0, handler: nil)

        isTestCompleted = true
        tcpClient.close()
    }

    func testConnectFailTimeout() {
        let clientQueue = dispatch_queue_create("testConnect-Client", DISPATCH_QUEUE_CONCURRENT)

        let expectation = expectationWithDescription("Connection time-out")
        let address = sockaddr_storage(IPv4: "10.91.177.0", port: 55912)

        var isTestCompleted = false
        let timeout = dispatch_walltime(nil, Int64(1 * NSEC_PER_SEC))
        let tcpClient = Socket(connect: address, queue: clientQueue, timeout: timeout) {
            switch $0 {
            case .POSIXError(ETIMEDOUT), .POSIXError(ENETUNREACH):
                expectation.fulfill()
                break
            default:
                if !isTestCompleted {
                    XCTFail("\($0)")
                }
                break
            }
        }

        waitForExpectationsWithTimeout(3.0, handler: nil)

        isTestCompleted = true
        tcpClient.close()
    }
}

*/