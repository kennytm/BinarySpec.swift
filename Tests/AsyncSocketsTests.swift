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
import CocoaAsyncSocket
import Result
@testable import BinarySpec

class ReadTest: XCTestCase {
    func testRead() {
        let clientHandlerQueue = dispatch_queue_create("ClientHandlerQueue", DISPATCH_QUEUE_CONCURRENT)

        let serverReadySemaphore = dispatch_semaphore_create(0)
        runReadServer(serverReadySemaphore, port: 40515)

        let readSemaphore = dispatch_semaphore_create(0)

        var readResult = [Result<[BinaryData], NSError>]()
        let socket = BinarySocket(spec: BinarySpec(parse: ">%B(I)"), handlerQueue: clientHandlerQueue) { arg in
            readResult.append(arg)
            if case .Failure = arg {
                dispatch_semaphore_signal(readSemaphore)
            }
        }

        dispatch_semaphore_wait(serverReadySemaphore, DISPATCH_TIME_FOREVER)
        usleep(10_000)

        socket.connect(IPAddress.localhost.withPort(40515))

        dispatch_semaphore_wait(readSemaphore, DISPATCH_TIME_FOREVER)

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
        XCTAssertEqual(readResult[2],
                       domain: GCDAsyncSocketErrorDomain,
                       code: GCDAsyncSocketError.ClosedError.rawValue)
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

        let lotsOfData = NSMutableData(length: 67890)!
        var lotsOfDataBytes = UnsafeMutablePointer<UInt8>(lotsOfData.mutableBytes)
        for i in 0 ..< lotsOfData.length {
            lotsOfDataBytes.memory = UInt8(truncatingBitPattern: i &* i)
            lotsOfDataBytes = lotsOfDataBytes.advancedBy(1)
        }

        let binData = BinaryData.Seq([
            .Integer(UIntMax(lotsOfData.length)),
            .Bytes(lotsOfData),
            ])

        let serverReadySemaphore = dispatch_semaphore_create(0)
        runWriteServer(serverReadySemaphore, port: 55016)

        dispatch_semaphore_wait(serverReadySemaphore, DISPATCH_TIME_FOREVER)
        usleep(10_000)

        let dg = dispatch_group_create()
        var readResult = BinaryData.Empty
        let expectation = expectationWithDescription("Everything written")

        dispatch_group_enter(dg)
        let socket = BinarySocket(spec: BinarySpec(parse: "<%Is"), handlerQueue: clientSocketQueue) {
            switch $0 {
            case let .Success(results):
                precondition(readResult == BinaryData.Empty)
                precondition(results.count == 1)
                readResult = results[0]
                dispatch_group_leave(dg)
            case let .Failure(e):
                precondition(e.domain == GCDAsyncSocketErrorDomain && e.code == GCDAsyncSocketError.ClosedError.rawValue)
            }
        }

        socket.connect(IPAddress.localhost.withPort(55016), timeout: -1)

        dispatch_group_enter(dg)
        socket.write(binData) {
            print($0)
            precondition($0 == nil)
            dispatch_group_leave(dg)
        }

        dispatch_async(waitQueue) {
            dispatch_group_wait(dg, DISPATCH_TIME_FOREVER)
            expectation.fulfill()
        }

        waitForExpectationsWithTimeout(2.0, handler: nil)

        XCTAssertEqual(readResult[0], BinaryData.Integer(UIntMax(lotsOfData.length)))
        let readData = readResult[1].bytes
        let readBytes = linearize(readData)
        XCTAssertEqual(readBytes.count, lotsOfData.length)
        for (i, j) in zip(readBytes, linearize(lotsOfData)) {
            XCTAssertEqual(i, j ^ 0x75)
        }
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

class FailingSocketTests: XCTestCase {
    func testConnectFailTimeout() {
        let expectation = expectationWithDescription("Connection time-out")

        let client = BinarySocket(spec: BinarySpec(parse: ">B"), handlerQueue: dispatch_get_main_queue()) { result in
            switch result {
            case let .Failure(e) where e.domain == GCDAsyncSocketErrorDomain:
                switch GCDAsyncSocketError(rawValue: e.code) {
                case .ConnectTimeoutError?:
                    expectation.fulfill()
                    return
                default:
                    break
                }
            default:
                break
            }

            XCTFail("unexpected \(result)")
        }

        client.connect(IPAddress(string: "10.91.177.0")!.withPort(55912), timeout: 1.0)
        defer { client.disconnect() }

        waitForExpectationsWithTimeout(3.0, handler: nil)
    }

    func testConnectFailLocal() {
        let expectation = expectationWithDescription("Connection time-out")

        let client = BinarySocket(spec: BinarySpec(parse: ">B"), handlerQueue: dispatch_get_main_queue()) { result in
            switch result {
            case let .Failure(e) where e.domain == NSPOSIXErrorDomain:
                switch POSIXError(rawValue: CInt(e.code)) {
                case .ECONNREFUSED?:
                    expectation.fulfill()
                    return
                default:
                    break
                }
            default:
                break
            }

            XCTFail("unexpected \(result)")
        }

        client.connect(IPAddress.localhost.withPort(41948), timeout: 1.0)
        defer { client.disconnect() }

        waitForExpectationsWithTimeout(3.0, handler: nil)
    }
}


