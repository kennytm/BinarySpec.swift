//
//  BinarySpecTests.swift
//  BinarySpecTests
//
//  Created by kennytm on 15-12-05.
//  Copyright © 2015 kennytm. All rights reserved.
//

import XCTest
@testable import BinarySpec

func XCTAssertEqual<T: Equatable>(lhs: Partial<SliceQueue<T>>, _ rhs: ArraySlice<T>) {
    XCTAssertEqual(lhs, Partial.Ok(SliceQueue([rhs])))
}

func XCTAssertEqual<T: Equatable>(lhs: SliceQueue<T>, _ rhs: ArraySlice<T>) {
    XCTAssertEqual(lhs, SliceQueue([rhs]))
}

class SliceQueueTest: XCTestCase {
    func testEqual() {
        let queue1 = SliceQueue<Int>([[1,2,3,4,5], [6,7], [8], [9,10], [11,12,13,14,15,16]])
        let queue2 = SliceQueue<Int>([[1,2,3,4], [5,6,7], [8,9,10,11,12,13,14,15,16]])
        let queue3 = SliceQueue<Int>([[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17]])
        let queue4 = SliceQueue<Int>([[1],[2],[3],[4,5,6,7,8,9,-1,-2]])

        XCTAssertEqual(queue1, queue2)
        XCTAssertEqual(queue2, queue1)

        XCTAssertEqual(queue1, queue1)
        XCTAssertEqual(queue2, queue2)
        XCTAssertEqual(queue3, queue3)
        XCTAssertEqual(queue4, queue4)

        XCTAssertNotEqual(queue1, queue3)
        XCTAssertNotEqual(queue1, queue4)
        XCTAssertNotEqual(queue2, queue3)
        XCTAssertNotEqual(queue2, queue4)
        XCTAssertNotEqual(queue3, queue1)
        XCTAssertNotEqual(queue3, queue2)
        XCTAssertNotEqual(queue3, queue4)
        XCTAssertNotEqual(queue4, queue1)
        XCTAssertNotEqual(queue4, queue2)
        XCTAssertNotEqual(queue4, queue3)
    }

    func testRemoveFirst() {
        var queue = SliceQueue<Int>([[1,2,3,4,5], [6,7], [8], [9,10], [11,12,13,14,15,16]])

        let first = queue.removeFirst(4)
        XCTAssertEqual(first, [1,2,3,4])
        XCTAssertEqual(queue, [5,6,7,8,9,10,11,12,13,14,15,16])

        let second = queue.removeFirst(1)
        XCTAssertEqual(second, [5])
        XCTAssertEqual(queue, [6,7,8,9,10,11,12,13,14,15,16])

        let third = queue.removeFirst(4)
        XCTAssertEqual(third, [6,7,8,9])
        XCTAssertEqual(queue, [10,11,12,13,14,15,16])

        let fourth = queue.removeFirst(7)
        XCTAssertEqual(fourth, [10,11,12,13,14,15,16])
        XCTAssertTrue(queue.isEmpty)

        let fifth = queue.removeFirst(4)
        XCTAssertEqual(fifth, Partial.Incomplete(requesting: 4))
    }

    func testRemoveFirstWithNotEnoughData() {
        var queue = SliceQueue<Int>([[1,2,3], [4,5,6]])

        let first = queue.removeFirst(20)
        XCTAssertEqual(first, Partial.Incomplete(requesting: 14))
        XCTAssertEqual(queue, [1,2,3,4,5,6])

        let second = queue.removeFirst(4)
        XCTAssertEqual(second, [1,2,3,4])
        XCTAssertEqual(queue, [5,6])

        let third = queue.removeFirst(4)
        XCTAssertEqual(third, Partial.Incomplete(requesting: 2))
        XCTAssertEqual(queue, [5,6])
    }

    func testEncodeExactly() {
        let queue = SliceQueue<Int>([[1, 2], [3, 4, 5, 6]])

        var res1 = [Int]()
        queue.encodeExactly(5, padding: 0) { res1.appendContentsOf($0) }
        XCTAssertEqual(res1, [1, 2, 3, 4, 5])

        var res2 = [Int]()
        queue.encodeExactly(6, padding: 0) { res2.appendContentsOf($0) }
        XCTAssertEqual(res2, [1, 2, 3, 4, 5, 6])

        var res3 = [Int]()
        queue.encodeExactly(9, padding: 0) { res3.appendContentsOf($0) }
        XCTAssertEqual(res3, [1, 2, 3, 4, 5, 6, 0, 0, 0])

        var res4 = [Int]()
        queue.encode { res4.appendContentsOf($0) }
        XCTAssertEqual(res4, [1, 2, 3, 4, 5, 6])
    }
}

class IntSpecTest: XCTestCase {
    func testDecode() {
        let data = ArraySlice<UInt8>([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x12, 0x34])

        XCTAssertEqual(data.toUIntMax(.Byte), 0xaa)
        XCTAssertEqual(data.toUIntMax(.UInt16LE), 0xbbaa)
        XCTAssertEqual(data.toUIntMax(.UInt16BE), 0xaabb)
        XCTAssertEqual(data.toUIntMax(.UInt32LE), 0xddccbbaa)
        XCTAssertEqual(data.toUIntMax(.UInt32BE), 0xaabbccdd)
        XCTAssertEqual(data.toUIntMax(.UInt64LE), 0x3412ffee_ddccbbaa)
        XCTAssertEqual(data.toUIntMax(.UInt64BE), 0xaabbccdd_eeff1234)
    }

    func testEncode() {
        var calledCount = 0
        IntSpec.Byte.encode(0x95) { XCTAssertEqual(Array($0), [0x95]); calledCount += 1 }
        IntSpec.UInt16LE.encode(0x2051) { XCTAssertEqual(Array($0), [0x51, 0x20]); calledCount += 1 }
        IntSpec.UInt16BE.encode(0x2051) { XCTAssertEqual(Array($0), [0x20, 0x51]); calledCount += 1 }
        IntSpec.UInt32LE.encode(0x33419c) { XCTAssertEqual(Array($0), [0x9c, 0x41, 0x33, 0x00]); calledCount += 1 }
        IntSpec.UInt32BE.encode(0x33419c) { XCTAssertEqual(Array($0), [0x00, 0x33, 0x41, 0x9c]); calledCount += 1 }
        IntSpec.UInt64LE.encode(0x532_94ccba00) { XCTAssertEqual(Array($0), [0x00, 0xba, 0xcc, 0x94, 0x32, 0x05, 0x00, 0x00]); calledCount += 1 }
        IntSpec.UInt64BE.encode(0x532_94ccba00) { XCTAssertEqual(Array($0), [0x00, 0x00, 0x05, 0x32, 0x94, 0xcc, 0xba, 0x00]); calledCount += 1 }
        XCTAssertEqual(calledCount, 7)
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
        let result = try! parser.next().unwrap()

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
        let result = try! parser.next().unwrap()

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
        XCTAssertEqual(result1, Partial.Incomplete(requesting: 6))

        parser.supply([0x55, 0x77])
        let result2 = parser.next()
        XCTAssertEqual(result2, Partial.Incomplete(requesting: 4))

        parser.supply([0xaa, 0xbc, 0xde, 0xff, 0x13])
        let result3 = parser.next()
        XCTAssertEqual(result3, Partial.Ok(.Empty))
        XCTAssertEqual(parser.remaining, [0x13])
    }

    func testBytes() {
        let parser = BinaryParser(.Seq([.Variable(.UInt16LE, "bytes"), .Bytes("bytes")]))
        parser.supply([0x10, 0, 1, 2, 3, 4, 5])

        let result1 = parser.next()
        XCTAssertEqual(result1, Partial.Incomplete(requesting: 11))

        parser.supply([6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24])
        let result2 = parser.next()
        let expected = BinaryData.Seq([
            .Integer(0x10),
            .Bytes(SliceQueue([[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]])),
            ])
        XCTAssertEqual(result2, Partial.Ok(expected))
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
        XCTAssertEqual(result1, Partial.Incomplete(requesting: 3))

        parser.supply([3, 4, 5])
        let result2 = parser.next()
        XCTAssertEqual(result2, Partial.Incomplete(requesting: 2))

        parser.supply([0, 0])
        let result3 = parser.next()
        XCTAssertEqual(result3, Partial.Ok(.Seq([
            .Integer(5),
            .Bytes(SliceQueue([[1, 2, 3, 4, 5]])),
            .Integer(0),
            .Bytes(SliceQueue([]))
            ])))
    }

    func testUntil() {
        let parser = BinaryParser(.Seq([
            .Variable(.Byte, "length"),
            .Until("length", .Integer(.UInt32LE))
            ]))

        parser.supply([13, 0x12, 0x34, 0x55, 0x78])
        let result1 = parser.next()
        XCTAssertEqual(result1, Partial.Incomplete(requesting: 9))

        parser.supply([0x00, 0x00, 0x31, 0x4a, 0xa8, 0x93, 0xa3, 0x85, 0x92, 0x1b, 0xc3, 0x59])
        let result2 = parser.next()
        XCTAssertEqual(result2, Partial.Ok(.Seq([
            .Integer(13),
            .Seq([
                .Integer(0x78553412),
                .Integer(0x4a310000),
                .Integer(0x85a393a8)
                ]),
            ])))
        XCTAssertEqual(parser.remaining, [0x1b, 0xc3, 0x59]) // note that the 0x92 is consumed.
    }

    func testUntilComplete() {
        let parser = BinaryParser(.Seq([
            .Variable(.Byte, "length"),
            .Until("length", .Integer(.UInt32LE))
            ]))
        parser.supply([4, 1,2,3,4])
        let result = try! parser.next().unwrap()
        XCTAssertEqual(result, BinaryData.Seq([.Integer(4), .Seq([.Integer(0x04030201)])]))
    }

    func testUntilEmpty() {
        let parser = BinaryParser(.Seq([
            .Variable(.Byte, "length"),
            .Until("length", .Integer(.UInt32LE))
            ]))
        parser.supply([0])
        let result = try! parser.next().unwrap()
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
        XCTAssertEqual(result, Partial.Ok(.Stop(switchSpec, 0x99)))
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
        XCTAssertEqual(result, Partial.Ok(.Stop(.Stop, 0)))
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
        XCTAssertEqual(result, Partial.Ok(.Seq([
            .Integer(4),
            .Integer(9),
            .Seq([.Seq([.Integer(7), .Integer(3)])]),
            .Integer(8),
            ])))
    }
}