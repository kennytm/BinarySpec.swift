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

class DispatchDataTest: XCTestCase {
    func testLinearize() {
        var dd = dispatch_data_empty
        dd += [1,2,3,4,5]
        dd += [6,7]
        dd += [8]
        dd += [9,10]
        dd += [11,12,13,14,15,16]

        let buffer = linearize(&dd)
        XCTAssertEqual(Array(buffer), [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16])
    }

    func testSplitAt() {
        var queue = dispatch_data_empty
        var prefix: dispatch_data_t
        queue += [1,2,3,4,5]
        queue += [6,7]
        queue += [8]
        queue += [9,10]
        queue += [11,12,13,14,15,16]

        (prefix, queue) = try! queue.splitAt(4)
        XCTAssertEqual(prefix, [1,2,3,4])
        XCTAssertEqual(queue, [5,6,7,8,9,10,11,12,13,14,15,16])

        (prefix, queue) = try! queue.splitAt(1)
        XCTAssertEqual(prefix, [5])
        XCTAssertEqual(queue, [6,7,8,9,10,11,12,13,14,15,16])

        (prefix, queue) = try! queue.splitAt(4)
        XCTAssertEqual(prefix, [6,7,8,9])
        XCTAssertEqual(queue, [10,11,12,13,14,15,16])

        (prefix, queue) = try! queue.splitAt(7)
        XCTAssertEqual(prefix, [10,11,12,13,14,15,16])
        XCTAssertTrue(queue.isEmpty)

        do {
            try queue.splitAt(4)
            XCTFail()
        } catch let e as IncompleteError {
            XCTAssertEqual(e.requestedCount, 4)
        } catch {
            XCTFail()
        }
    }

    func testResized() {
        var queue = dispatch_data_empty
        queue += [1, 2]
        queue += [3, 4, 5, 6]

        let res1 = queue.resized(5)
        XCTAssertEqual(res1, [1, 2, 3, 4, 5])

        let res2 = queue.resized(6)
        XCTAssertEqual(res2, [1, 2, 3, 4, 5, 6])

        let res3 = queue.resized(9)
        XCTAssertEqual(res3, [1, 2, 3, 4, 5, 6, 0, 0, 0])

        XCTAssertEqual(queue, [1, 2, 3, 4, 5, 6])
    }
}

class IntSpecTest: XCTestCase {
    func testDecode() {
        var data = dispatch_data_empty
        data += [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x12, 0x34]

        XCTAssertEqual(data.toUIntMax(.Byte), 0xaa)
        XCTAssertEqual(data.toUIntMax(.UInt16LE), 0xbbaa)
        XCTAssertEqual(data.toUIntMax(.UInt16BE), 0xaabb)
        XCTAssertEqual(data.toUIntMax(.UInt32LE), 0xddccbbaa)
        XCTAssertEqual(data.toUIntMax(.UInt32BE), 0xaabbccdd)
        XCTAssertEqual(data.toUIntMax(.UInt64LE), 0x3412ffee_ddccbbaa)
        XCTAssertEqual(data.toUIntMax(.UInt64BE), 0xaabbccdd_eeff1234)
    }

    func testEncode() {
        XCTAssertEqual(IntSpec.Byte.encode(0x95), [0x95])
        XCTAssertEqual(IntSpec.UInt16LE.encode(0x2051), [0x51, 0x20])
        XCTAssertEqual(IntSpec.UInt16BE.encode(0x2051), [0x20, 0x51])
        XCTAssertEqual(IntSpec.UInt32LE.encode(0x33419c), [0x9c, 0x41, 0x33, 0x00])
        XCTAssertEqual(IntSpec.UInt32BE.encode(0x33419c), [0x00, 0x33, 0x41, 0x9c])
        XCTAssertEqual(IntSpec.UInt64LE.encode(0x532_94ccba00), [0x00, 0xba, 0xcc, 0x94, 0x32, 0x05, 0x00, 0x00])
        XCTAssertEqual(IntSpec.UInt64BE.encode(0x532_94ccba00), [0x00, 0x00, 0x05, 0x32, 0x94, 0xcc, 0xba, 0x00])        
    }
}

class BinaryParserTest: XCTestCase {
    func testSeqOfIntBE() {
        let parser = BinaryParser(.Seq([
            .Integer(.Byte),
            .Integer(.UInt16BE),
            .Integer(.UInt32BE),
            .Integer(.UInt64BE)
            ]))
        parser.supply([0x12, 0x12, 0x34, 0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0])
        let result = try! parser.next().dematerialize()

        XCTAssertEqual(result, BinaryData.Seq([
            .Integer(0x12),
            .Integer(0x1234),
            .Integer(0x12345678),
            .Integer(0x12345678_9abcdef0)
            ]))
    }

    func testSeqOfIntLE() {
        let parser = BinaryParser(.Seq([
            .Integer(.Byte),
            .Integer(.UInt16LE),
            .Integer(.UInt32LE),
            .Integer(.UInt64LE)
            ]))
        parser.supply([0x12, 0x12, 0x34, 0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0])
        let result = try! parser.next().dematerialize()

        XCTAssertEqual(result, BinaryData.Seq([
            .Integer(0x12),
            .Integer(0x3412),
            .Integer(0x78563412),
            .Integer(0xf0debc9a_78563412)
            ]))
    }

    func testSkip() {
        let parser = BinaryParser(.Skip(10))

        parser.supply([0x12, 0x34, 0x56, 0x78])
        let result1 = parser.next()
        XCTAssertEqual(result1, error: IncompleteError(requestedCount: 6))

        parser.supply([0x55, 0x77])
        let result2 = parser.next()
        XCTAssertEqual(result2, error: IncompleteError(requestedCount: 4))

        parser.supply([0xaa, 0xbc, 0xde, 0xff, 0x13])
        let result3 = parser.next()
        XCTAssertEqual(result3, success: .Empty)
        XCTAssertEqual(parser.remaining, [0x13])
    }

    func testBytes() {
        let parser = BinaryParser(.Seq([.Variable(.UInt16LE, "bytes"), .Bytes("bytes")]))
        parser.supply([0x10, 0, 1, 2, 3, 4, 5])

        let result1 = parser.next()
        XCTAssertEqual(result1, error: IncompleteError(requestedCount: 11))

        parser.supply([6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24])
        let result2 = parser.next()
        let expected = BinaryData.Seq([
            .Integer(0x10),
            .Bytes(createData([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16])),
            ])
        XCTAssertEqual(result2, success: expected)
        XCTAssertEqual(parser.remaining, [17,18,19,20,21,22,23,24])
    }

    func testIncompleteSeq() {
        let parser = BinaryParser(.Seq([
            .Variable(.UInt16BE, "first"),
            .Bytes("first"),
            .Variable(.UInt16BE, "second"),
            .Bytes("second"),
            ]))
        parser.supply([0, 5, 1, 2])

        let result1 = parser.next()
        XCTAssertEqual(result1, error: IncompleteError(requestedCount: 3))

        parser.supply([3, 4, 5])
        let result2 = parser.next()
        XCTAssertEqual(result2, error: IncompleteError(requestedCount: 2))

        parser.supply([0, 0])
        let result3 = parser.next()
        XCTAssertEqual(result3, success: .Seq([
            .Integer(5),
            .Bytes(createData([1, 2, 3, 4, 5])),
            .Integer(0),
            .Bytes(dispatch_data_empty)
            ]))
    }

    func testUntil() {
        let parser = BinaryParser(.Seq([
            .Variable(.Byte, "length"),
            .Until("length", .Integer(.UInt32LE))
            ]))

        parser.supply([13, 0x12, 0x34, 0x55, 0x78])
        let result1 = parser.next()
        XCTAssertEqual(result1, error: IncompleteError(requestedCount: 9))

        parser.supply([0x00, 0x00, 0x31, 0x4a, 0xa8, 0x93, 0xa3, 0x85, 0x92, 0x1b, 0xc3, 0x59])
        let result2 = parser.next()
        XCTAssertEqual(result2, success: .Seq([
            .Integer(13),
            .Seq([
                .Integer(0x78553412),
                .Integer(0x4a310000),
                .Integer(0x85a393a8)
                ]),
            ]))
        XCTAssertEqual(parser.remaining, [0x1b, 0xc3, 0x59]) // note that the 0x92 is consumed.
    }

    func testUntilComplete() {
        let parser = BinaryParser(.Seq([
            .Variable(.Byte, "length"),
            .Until("length", .Integer(.UInt32LE))
            ]))
        parser.supply([4, 1,2,3,4])
        let result = try! parser.next().dematerialize()
        XCTAssertEqual(result, BinaryData.Seq([.Integer(4), .Seq([.Integer(0x04030201)])]))
    }

    func testUntilEmpty() {
        let parser = BinaryParser(.Seq([
            .Variable(.Byte, "length"),
            .Until("length", .Integer(.UInt32LE))
            ]))
        parser.supply([0])
        let result = try! parser.next().dematerialize()
        XCTAssertEqual(result, BinaryData.Seq([.Integer(0), .Seq([])]))
    }

    func testSwitch() {
        let spec = BinarySpec.Seq([
            .Variable(.Byte, "selector"),
            .Switch(selector: "selector", cases: [
                0: .Integer(.Byte),
                1: .Integer(.UInt16BE),
                2: .Integer(.UInt32BE),
                3: .Integer(.UInt64BE),
                ], `default`: .Integer(.UInt16LE))
            ])

        let parser = BinaryParser(spec)
        parser.supply([
            1, 0x34, 0x56,
            2, 0x22, 0x99, 0x0, 0x0,
            0, 0x03,
            3, 0x61, 0x61, 0x61, 0x61, 0x73, 0x73, 0x73, 0x73,
            98, 0x6d, 0x39,
            109])

        let result = parser.parseAll()

        XCTAssertEqual(result, [
            .Seq([.Integer(1), .Integer(0x3456)]),
            .Seq([.Integer(2), .Integer(0x22990000)]),
            .Seq([.Integer(0), .Integer(0x03)]),
            .Seq([.Integer(3), .Integer(0x61616161_73737373)]),
            .Seq([.Integer(98), .Integer(0x396d)]),
        ])
    }

    func testSwitchStop() {
        let switchSpec = BinarySpec.Switch(selector: "selector", cases: [0: .Integer(.Byte)], `default`: .Stop)

        let parser = BinaryParser(.Seq([.Variable(.Byte, "selector"), switchSpec]))
        parser.supply([0x99, 0xcc])

        let result = parser.next()
        XCTAssertEqual(result, success: .Stop(switchSpec, 0x99))
    }

    // A .Stop should render the entire tree unusable until an `.Until`.
    func testStopInSeq() {
        let parser = BinaryParser(.Seq([
            .Integer(.Byte),
            .Integer(.Byte),
            .Stop,
            .Integer(.Byte),
        ]))

        parser.supply([1,2,3,4,5])

        let result = parser.next()
        XCTAssertEqual(result, success: .Stop(.Stop, 0))
    }

    func testStopInUntil() {
        let parser = BinaryParser(.Seq([
            .Variable(.Byte, "length"),
            .Integer(.Byte),
            .Until("length", .Seq([
                .Variable(.Byte, "selector"),
                .Switch(selector: "selector", cases: [7: .Integer(.Byte)], `default`: .Stop)
                ])),
            .Integer(.Byte),
        ]))

        parser.supply([4,9, 7,3,5,0, 8])

        let result = parser.next()
        XCTAssertEqual(result, success: .Seq([
            .Integer(4),
            .Integer(9),
            .Seq([.Seq([.Integer(7), .Integer(3)])]),
            .Integer(8),
            ]))
    }

    func testReadAgain() {
        let parser = BinaryParser(.Seq([
            .Integer(.UInt32LE),
            .Integer(.UInt32LE),
            ]))

        parser.supply([1,2,3,4,5,6,7,8])
        let result = parser.next()
        XCTAssertEqual(result, success: .Seq([
            .Integer(0x04030201),
            .Integer(0x08070605),
            ]))

        parser.resetStates()
        parser.supply([9,0,1,2,3,4,5,6,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88])
        let result2 = parser.next()
        XCTAssertEqual(result2, success: .Seq([
            .Integer(0x02010009),
            .Integer(0x06050403),
            ]))

        parser.resetStates()
        let result3 = parser.next()
        XCTAssertEqual(result3, success: .Seq([
            .Integer(0x44332211),
            .Integer(0x88776655),
            ]))
    }
}

class BinaryEncoderTest: XCTestCase {
    func testEncodeIntSeq() {
        let data = BinaryData.Seq([
            .Integer(0x0badf00d_deadba11),
            .Integer(0x20121221),
            .Integer(0x2468),
            .Integer(0x13),
            ])

        let spec = BinarySpec.Seq([
            .Integer(.UInt64BE),
            .Integer(.UInt32LE),
            .Integer(.UInt32BE),
            .Integer(.UInt32LE),
            ])

        let encoder = BinaryEncoder(spec)

        let result = encoder.encode(data)
        XCTAssertEqual(result, [
            0x0b, 0xad, 0xf0, 0x0d, 0xde, 0xad, 0xba, 0x11,
            0x21, 0x12, 0x12, 0x20,
            0, 0, 0x24, 0x68,
            0x13, 0, 0, 0
            ])
    }

    func testEncodeBytes() {
        let bytes = Array("aaabbbcccdddeeefffggghhhiiijjjkkklllmmmnnnoooppp".utf8)

        let data = BinaryData.Seq([
            .Integer(UIntMax(bytes.count)),
            .Bytes(createData(bytes))
            ])

        let spec = BinarySpec.Seq([
            .Variable(.UInt16BE, "length"),
            .Bytes("length")
            ])

        let encoder = BinaryEncoder(spec)

        let result = encoder.encode(data)

        let expected = [UInt8]([0, 0x30] + bytes)
        XCTAssertEqual(result, expected)
    }
}
