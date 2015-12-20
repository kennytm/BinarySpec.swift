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

class SocketAddressTests: XCTestCase {
    func testIPv4ToString() {
        let ip = in_addr(s_addr: inet_addr("192.168.57.1"))
        let inetAddress = IPAddress(ip)
        XCTAssertEqual(inetAddress.stringValue, "192.168.57.1")
    }

    func testIPv6ToString() {
        let inetAddress = IPAddress(in6addr_nodelocal_allnodes)
        XCTAssertEqual(inetAddress.stringValue, "ff01::1")
    }

    func testParseIPv4Sockaddr() {
        var addr = sockaddr(sa_len: 16, sa_family: 2, sa_data: (0x2b, -0x7, -0x40, -0x58, 0x06, 0x5f, 0,0,0,0,0,0,0,0))
        let socketAddress = SocketAddress(&addr)!
        XCTAssertEqual(socketAddress.stringValue, "192.168.6.95:11257")
    }

    func testRange() {
        let localIP = IPAddress(in_addr(s_addr: inet_addr("192.168.6.180")))
        let netmask = IPAddress(in_addr(s_addr: inet_addr("255.255.254.0")))

        let startIP = localIP.mask(netmask)!
        let subnetSize = netmask.subnetSize
        let endIP = startIP.advancedBy(subnetSize)

        let ipList = (startIP ..< endIP).map { $0.stringValue }
        let expectedIPList = (0 ... 255).map { "192.168.6.\($0)" } + (0 ... 255).map { "192.168.7.\($0)" }
        XCTAssertEqual(ipList, expectedIPList)
    }

    func testStringToIPv4() {
        let ip1 = IPAddress(in_addr(s_addr: inet_addr("210.6.229.31")))
        let ip2 = IPAddress(string: "210.6.229.31")!
        XCTAssertEqual(ip1, ip2)
    }

    func testStringToIPv4Failure() {
        let ip = IPAddress(string: "not_an_ip")
        XCTAssertNil(ip)
    }

}
