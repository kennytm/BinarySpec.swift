//
//  Utils.swift
//  BinarySpec
//
//  Created by kennytm on 15-12-09.
//  Copyright © 2015 kennytm. All rights reserved.
//

import XCTest
import BinarySpec
import Result

public func printStackTrace() {
    let trace = NSThread.callStackSymbols().suffixFrom(1)
    let demangled = trace.map { line -> String in
        guard let range = line.rangeOfString("_T\\S+", options: .RegularExpressionSearch, range: nil, locale: nil) else {
            return line
        }
        let name = _stdlib_demangleName(line[range])
        return line.stringByReplacingCharactersInRange(range, withString: name)
    }
    print(demangled.joinWithSeparator("\n"))
}

public func XCTAssertEqual(left: NSData, _ right: [UInt8], file: StaticString = #file, line: UInt = #line) {
    let leftBuffer = linearize(left)
    right.withUnsafeBufferPointer { rightBuffer in
        XCTAssertEqual(leftBuffer.count, rightBuffer.count, file: file, line: line)
        XCTAssertEqual(memcmp(leftBuffer.baseAddress, rightBuffer.baseAddress, leftBuffer.count), 0, file: file, line: line)
    }
}

public func XCTAssertEqual<L, R: Equatable>(res: Result<L, R>, error: R, file: StaticString = #file, line: UInt = #line) {
    guard case let .Failure(e) = res else {
        XCTFail("\(res) is not an error", file: file, line: line)
        return
    }
    XCTAssertEqual(e, error, file: file, line: line)
}

public func XCTAssertEqual<L>(res: Result<L, NSError>, domain: NSString, code: Int, file: StaticString = #file, line: UInt = #line) {
    guard case let .Failure(e) = res else {
        XCTFail("\(res) is not an NSError", file: file, line: line)
        return
    }
    XCTAssertEqual(e.domain, domain, file: file, line: line)
    XCTAssertEqual(e.code, code, file: file, line: line)
}

public func XCTAssertEqual<L: Equatable, R>(res: Result<L, R>, success: L, file: StaticString = #file, line: UInt = #line) {
    guard case let .Success(s) = res else {
        XCTFail("\(res) is not a success", file: file, line: line)
        return
    }
    XCTAssertEqual(s, success, file: file, line: line)
}

public func XCTAssertEqual<L: Equatable, R>(res: Result<[L], R>, success: [L], file: StaticString = #file, line: UInt = #line) {
    guard case let .Success(s) = res else {
        XCTFail("\(res) is not a success", file: file, line: line)
        return
    }
    XCTAssertEqual(s, success, file: file, line: line)
}

