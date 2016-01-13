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
import BinarySpec

class BinarySpecParserTests: XCTestCase {
    func testSingleton() {
        XCTAssertEqual(BinarySpec(parse: "<b"), BinarySpec.Integer(.Byte))
        XCTAssertEqual(BinarySpec(parse: "<h"), BinarySpec.Integer(.UInt16LE))
        XCTAssertEqual(BinarySpec(parse: ">h"), BinarySpec.Integer(.UInt16BE))
        XCTAssertEqual(BinarySpec(parse: "<t"), BinarySpec.Integer(.UInt24LE))
        XCTAssertEqual(BinarySpec(parse: ">t"), BinarySpec.Integer(.UInt24BE))
        XCTAssertEqual(BinarySpec(parse: "<i"), BinarySpec.Integer(.UInt32LE))
        XCTAssertEqual(BinarySpec(parse: ">i"), BinarySpec.Integer(.UInt32BE))
        XCTAssertEqual(BinarySpec(parse: "<q"), BinarySpec.Integer(.UInt64LE))
        XCTAssertEqual(BinarySpec(parse: ">q"), BinarySpec.Integer(.UInt64BE))
    }

    func testRepeat() {
        XCTAssertEqual(BinarySpec(parse: ">3Q<2Q"), BinarySpec.Seq([
            .Integer(.UInt64BE),
            .Integer(.UInt64BE),
            .Integer(.UInt64BE),
            .Integer(.UInt64LE),
            .Integer(.UInt64LE),
            ]))
    }

    func testSkip() {
        XCTAssertEqual(BinarySpec(parse: "256x"), BinarySpec.Skip(256))
        XCTAssertEqual(BinarySpec(parse: "0x"), BinarySpec.Skip(0))
        XCTAssertEqual(BinarySpec(parse: "0x256x"), BinarySpec.Skip(0x256))
    }

    func testHexDigit() {
        XCTAssertEqual(BinarySpec(parse: "2bx"), BinarySpec.Seq([.Integer(.Byte), .Integer(.Byte), .Skip(1)]))
        XCTAssertEqual(BinarySpec(parse: "0x2bx"), BinarySpec.Skip(0x2b))
        XCTAssertEqual(BinarySpec(parse: "0x2 bx"), BinarySpec.Seq([.Integer(.Byte), .Integer(.Byte), .Skip(1)]))
        XCTAssertEqual(BinarySpec(parse: "00x2bx"), BinarySpec.Seq([.Skip(0), .Integer(.Byte), .Integer(.Byte), .Skip(1)]))
        XCTAssertEqual(BinarySpec(parse: "0 0x2bx"), BinarySpec.Skip(0x2b))
    }

    func testVariable() {
        XCTAssertEqual(BinarySpec(parse: "%Is"), BinarySpec.Seq([
            .Variable(.UInt32LE, "0", offset: 0),
            .Bytes("0")
            ]))
        XCTAssertEqual(BinarySpec(parse: "%I%Qss"), BinarySpec.Seq([
            .Variable(.UInt32LE, "0", offset: 0),
            .Variable(.UInt64LE, "1", offset: 0),
            .Bytes("0"),
            .Bytes("1")
            ]))
        XCTAssertEqual(BinarySpec(parse: "%I%Qss", variablePrefix: "hello_"), BinarySpec.Seq([
            .Variable(.UInt32LE, "hello_0", offset: 0),
            .Variable(.UInt64LE, "hello_1", offset: 0),
            .Bytes("hello_0"),
            .Bytes("hello_1")
            ]))
    }

    func testUntil() {
        XCTAssertEqual(BinarySpec(parse: "%T(I)"), BinarySpec.Seq([
            .Variable(.UInt24LE, "0", offset: 0),
            .Until("0", .Integer(.UInt32LE))
            ]))

        XCTAssertEqual(BinarySpec(parse: "%BB(BI)"), BinarySpec.Seq([
            .Variable(.Byte, "0", offset: 0),
            .Integer(.Byte),
            .Until("0", .Seq([
                .Integer(.Byte),
                .Integer(.UInt32LE),
                ]))
            ]))
    }

    func testSwitch() {
        XCTAssertEqual(BinarySpec(parse: "%I{1=T,2=B,0xa=QQ,*=H}"), BinarySpec.Seq([
            .Variable(.UInt32LE, "0", offset: 0),
            .Switch(selector: "0", cases: [
                1: .Integer(.UInt24LE),
                2: .Integer(.Byte),
                0xa: .Seq([.Integer(.UInt64LE), .Integer(.UInt64LE)])
                ], `default`: .Integer(.UInt16LE))
            ]))
    }

    func testSampleADB() {
        XCTAssertEqual(BinarySpec(parse: "<3I%I2Is"), BinarySpec.Seq([
            .Integer(.UInt32LE),
            .Integer(.UInt32LE),
            .Integer(.UInt32LE),
            .Variable(.UInt32LE, "0", offset: 0),
            .Integer(.UInt32LE),
            .Integer(.UInt32LE),
            .Bytes("0")
            ]))
    }

    func testSampleHTTP2() {
        XCTAssertEqual(BinarySpec(parse: ">%TBBIs"), BinarySpec.Seq([
            .Variable(.UInt24BE, "0", offset: 0),
            .Integer(.Byte),
            .Integer(.Byte),
            .Integer(.UInt32BE),
            .Bytes("0"),
            ]))
    }

    func testVariableOffset() {
        XCTAssertEqual(BinarySpec(parse: ">%+1I%-0x13I"), BinarySpec.Seq([
            .Variable(.UInt32BE, "0", offset: 1),
            .Variable(.UInt32BE, "1", offset: -0x13),
            ]))
    }

    func testVariableOverride() {
        XCTAssertEqual(BinarySpec(parse: ">%I%H1$s0$s", variablePrefix: "~"), BinarySpec.Seq([
            .Variable(.UInt32BE, "~0", offset: 0),
            .Variable(.UInt16BE, "~1", offset: 0),
            .Bytes("~1"),
            .Bytes("~0"),
            ]))
    }

    func testUnlimitedLength() {
        XCTAssertEqual(BinarySpec(parse: "*s"), BinarySpec.Bytes(nil))
        XCTAssertEqual(BinarySpec(parse: ">*(I)"), BinarySpec.Until(nil, .Integer(.UInt32BE)))

        XCTAssertEqual(BinarySpec(parse: ">%Is*s%Is"), BinarySpec.Seq([
            .Variable(.UInt32BE, "0", offset: 0),
            .Bytes("0"),
            .Bytes(nil),
            .Variable(.UInt32BE, "1", offset: 0),
            .Bytes("1"),
            ]))
    }
}

class BinaryDataConvertibleTests: XCTestCase {
    func testNumbers() {
        XCTAssertEqual(«5», BinaryData.Integer(5))
        XCTAssertEqual(«(-5)», BinaryData.Integer(UIntMax(bitPattern: -5)))
    }

    func testString() {
        XCTAssertEqual(«"Héĺĺó"», BinaryData.Bytes(createData([0x48, 0xc3, 0xa9, 0xc4, 0xba, 0xc4, 0xba, 0xc3, 0xb3])))
    }

    func testSequence() {
        XCTAssertEqual(«[1, 2, 4]», BinaryData.Seq([.Integer(1), .Integer(2), .Integer(4)]))
    }

    func testComposite() {
        XCTAssertEqual(«[«1», «[«3», «""»]»]», BinaryData.Seq([.Integer(1), .Seq([.Integer(3), .Bytes(dispatch_data_empty)])]))
    }
}
