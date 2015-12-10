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

    private func runClient(clientActions: (Connection, finish: () -> ()) -> ()) {
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

        var connection: Connection?
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

        var connection: Connection?
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

        var connection: Connection?
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

        var connection: Connection?
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
            case .POSIXError(ETIMEDOUT):
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
