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

// MARK: IPAddress

/// Represents an IP address
public enum IPAddress: Hashable, ForwardIndexType, CustomStringConvertible {
    /// An IPv4 address.
    case IPv4(in_addr)

    /// An IPv6 address.
    case IPv6(in6_addr, scopeId: UInt32)

    /// Refers to the localhost (127.0.0.1) in IPv4.
    public static let localhost = IPAddress.IPv4(in_addr(s_addr: UInt32(0x7f_00_00_01).bigEndian))

    /// Refers to the IPv4 address 0.0.0.0.
    public static let zero = IPAddress.IPv4(in_addr(s_addr: 0))

    /// Constructs an IPv4 address from the raw C structure.
    public init(_ addr: in_addr) {
        self = .IPv4(addr)
    }

    /// Constructs an IPv6 address from the raw C structure.
    public init(_ addr: in6_addr, scopeId: UInt32 = 0) {
        self = .IPv6(addr, scopeId: scopeId)
    }

    /// Parse the IP in the canonical string representation using `inet_pton(3)`. The strings should
    /// be in the form `192.168.6.11` for IPv4, or `fe80::1234:5678:9abc:def0%4` for IPv6.
    ///
    /// This method will not consult DNS (so host names like `www.example.com` will return nil here),
    /// nor will it parse the interface name (so you should use `%1` instead of `%lo0`).
    public init?(string: String) {
        let conversionResult: Int32
        if string.containsString(":") {
            var scopeId: UInt32 = 0
            var addr = in6_addr()
            if let percentRange = string.rangeOfString("%") {
                scopeId = UInt32(string.substringFromIndex(percentRange.endIndex)) ?? 0
            }
            conversionResult = inet_pton(AF_INET6, string, &addr)
            self = .IPv6(addr, scopeId: scopeId)
        } else {
            var addr = in_addr()
            conversionResult = inet_pton(AF_INET, string, &addr)
            self = .IPv4(addr)
        }
        if conversionResult != 1 {
            return nil
        }
    }

    /// Creates an IPv4 address from a 32-bit *network-endian* number.
    public init(IPv4Number number: UInt32) {
        let addr = in_addr(s_addr: number)
        self.init(addr)
    }

    /// Gets the string representation of the network address.
    public var stringValue: String {
        let callNToP = { (addrPtr: UnsafePointer<Void>, family: CInt, len: Int32) -> String in
            var buffer = [CChar](count: Int(len), repeatedValue: 0)
            inet_ntop(family, addrPtr, &buffer, socklen_t(len))
            return String.fromCString(buffer)!
        }

        switch self {
        case .IPv4(var addr):
            return callNToP(&addr, AF_INET, INET_ADDRSTRLEN)
        case .IPv6(var addr, let scopeId):
            let s = callNToP(&addr, AF_INET6, INET6_ADDRSTRLEN)
            if scopeId == 0 {
                return s
            } else {
                return "\(s)%\(scopeId)"
            }
        }
    }

    public var description: String {
        return stringValue
    }

    internal func stringValue(withBrackets withBrackets: Bool) -> String {
        if case .IPv6(_) = self {
            if withBrackets {
                return "[\(stringValue)]"
            }
        }
        return stringValue
    }

    /// Applies a network mask to this address, e.g. `192.168.6.22 & 255.255.255.0 ⇒ 192.168.6.0`
    public func mask(netmask: IPAddress) -> IPAddress? {
        switch (self, netmask) {
        case let (.IPv4(local), .IPv4(mask)):
            return .IPv4(in_addr(s_addr: local.s_addr & mask.s_addr))

        case let (.IPv6(local, scopeId: scopeId), .IPv6(mask)):
            let (local1, local2) = unsafeBitCast(local, (UInt64, UInt64).self)
            let (mask1, mask2) = unsafeBitCast(mask, (UInt64, UInt64).self)
            let result = unsafeBitCast((local1 & mask1, local2 & mask2), in6_addr.self)
            return .IPv6(result, scopeId: scopeId)

        default:
            return nil
        }
    }

    /// Compute thes size of subnet of this network mask IP. For instance, the subnet size of 
    /// `255.255.254.0` is 512.
    ///
    /// The IP must be like `255.255.255.0` or `ffff:ffff:ffff:ffff::`, otherwise the output will be
    /// undefined. If the subnet size is too large to fit in an `Int`, this property will return 
    /// `Int.max`.
    public var subnetSize: Int {
        switch self {
        case let .IPv4(addr):
            return Int(1 + ~UInt32(bigEndian: addr.s_addr))
        case let .IPv6(addr):
            let (loBig, _) = unsafeBitCast(addr, (UInt64, UInt64).self)
            let lo = ~UInt64(bigEndian: loBig)
            if lo >= UInt64(Int.max) {
                return Int.max
            } else {
                return Int(lo + 1)
            }
        }
    }

    public func successor() -> IPAddress {
        return advancedBy(1)
    }

    public func advancedBy(n: Int) -> IPAddress {
        switch self {
        case let .IPv4(addr):
            let nextIP: UInt32 = UInt32(bigEndian: addr.s_addr).advancedBy(n)
            return .IPv4(in_addr(s_addr: nextIP.bigEndian))
        case let .IPv6(addr, scopeId: scopeId):
            let (loBig, hiBig) = unsafeBitCast(addr, (UInt64, UInt64).self)
            let (hi, lo) = (UInt64(bigEndian: hiBig), UInt64(bigEndian: loBig))
            let newLo: UInt64, overflow: Bool, overflowValue: UInt64
            if n >= 0 {
                (newLo, overflow: overflow) = UInt64.addWithOverflow(lo, UInt64(n))
                overflowValue = overflow ? 1 : 0
            } else {
                (newLo, overflow: overflow) = UInt64.subtractWithOverflow(lo, UInt64(-n))
                overflowValue = overflow ? ~0 : 0
            }
            let newHi = hi &+ overflowValue
            let newAddr = unsafeBitCast((newLo.bigEndian, newHi.bigEndian), in6_addr.self)
            return .IPv6(newAddr, scopeId: scopeId)
        }
    }

    /// Gets the address family of this instance. Returns either `AF_INET` or `AF_INET6`.
    public var family: Int32 {
        switch self {
        case .IPv4(_): return AF_INET
        case .IPv6(_): return AF_INET6
        }
    }

    public var hashValue: Int {
        switch self {
        case let .IPv4(addr):
            return 4 |+> addr.s_addr
        case let .IPv6(addr, scopeId):
            let (lo, hi) = unsafeBitCast(addr, (UInt64, UInt64).self)
            return 6 |+> lo |+> hi |+> scopeId
        }
    }

    /// Constructs a new socket address at a given port.
    public func withPort(port: UInt16) -> SocketAddress {
        return .Internet(host: self, port: port)
    }
}

public func ==(lhs: IPAddress, rhs: IPAddress) -> Bool {
    switch (lhs, rhs) {
    case let (.IPv4(l), .IPv4(r)):
        return l.s_addr == r.s_addr
    case let (.IPv6(la, ls), .IPv6(ra, rs)):
        let (ll, lh) = unsafeBitCast(la, (UInt64, UInt64).self)
        let (rl, rh) = unsafeBitCast(ra, (UInt64, UInt64).self)
        return ll == rl && lh == rh && ls == rs
    default:
        return false
    }
}

// MARK: - Socket address

/// A wrapper of the C `sockaddr` structure.
public enum SocketAddress: Hashable {
    /// An internet address.
    case Internet(host: IPAddress, port: UInt16)

    /// Creates an internet address.
    public init(host: IPAddress, port: UInt16) {
        self = .Internet(host: host, port: port)
    }

    /// Converts an IPv4 `sockaddr_in` structure to a SocketAddress.
    public init(_ addr: sockaddr_in) {
        let host = IPAddress(addr.sin_addr)
        let port = UInt16(bigEndian: addr.sin_port)
        self = .Internet(host: host, port: port)
    }

    /// Converts an IPv4 `sockaddr_in6` structure to a SocketAddress.
    public init(_ addr: sockaddr_in6) {
        let host = IPAddress(addr.sin6_addr, scopeId: addr.sin6_scope_id)
        let port = UInt16(bigEndian: addr.sin6_port)
        self = .Internet(host: host, port: port)
    }

    /// Converts a generic `sockaddr` structure to a SocketAddress.
    public init?(_ addr: UnsafePointer<sockaddr>) {
        guard addr != nil else { return nil }

        switch Int32(addr.memory.sa_family) {
        case AF_INET:
            self.init(UnsafePointer<sockaddr_in>(addr).memory)
        case AF_INET6:
            self.init(UnsafePointer<sockaddr_in6>(addr).memory)
        default:
            return nil
        }
    }

    /// Converts a generic `sockaddr_storage` structure to a SocketAddress.
    public init?(_ addr: sockaddr_storage) {
        var storage = addr
        let ptr = withUnsafePointer(&storage) { UnsafePointer<sockaddr>($0) }
        self.init(ptr)
    }

    /// Obtains a SocketAddress instance from a function that outputs `sockaddr` structures. For
    /// example:
    ///
    /// ```swift
    /// let (addr, res) = SocketAddress.receive { accept(sck, $0, $1) }
    /// ```
    public static func receive<R>(@noescape closure: (UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) throws -> R) rethrows -> (SocketAddress?, R) {
        var storage = sockaddr_storage()
        var length = socklen_t(sizeofValue(storage))
        let result = try withUnsafeMutablePointers(&storage, &length) {
            try closure(UnsafeMutablePointer($0), $1)
        }
        let address = SocketAddress(storage)
        return (address, result)
    }

    public var stringValue: String {
        switch self {
        case let .Internet(host, port):
            return "\(host.stringValue(withBrackets: true)):\(port)"
        }
    }

    /// Converts this address into a `sockaddr_in` structure. If the address is not IPv4, it will 
    /// return nil.
    public func toIPv4() -> sockaddr_in? {
        guard case let .Internet(.IPv4(h), port) = self else { return nil }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(sizeofValue(addr))
        addr.sin_addr = h
        addr.sin_port = port.bigEndian
        return addr
    }

    /// Converts this address into a `sockaddr_in` structure. If the address is not IPv6, it will
    /// return nil.
    public func toIPv6() -> sockaddr_in6? {
        guard case let .Internet(.IPv6(h, scopeId), port) = self else { return nil }

        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_len = UInt8(sizeofValue(addr))
        addr.sin6_addr = h
        addr.sin6_port = port.bigEndian
        addr.sin6_scope_id = scopeId
        return addr
    }

    /// Converts this address into a `sockaddr` structure and performs some operation with it. For
    /// example:
    ///
    /// ```swift
    /// let address = IPAddress.localhost.withPort(80)
    /// let result = address.withSockaddr { connect(sck, $0, $1) }
    /// ```
    public func withSockaddr<R>(@noescape closure: (UnsafePointer<sockaddr>, socklen_t) throws -> R) rethrows -> R {
        switch self {
        case .Internet(.IPv4, _):
            var addr = toIPv4()!
            return try withUnsafePointer(&addr) {
                try closure(UnsafePointer($0), socklen_t(sizeofValue($0.memory)))
            }
        case .Internet(.IPv6, _):
            var addr = toIPv6()!
            return try withUnsafePointer(&addr) {
                try closure(UnsafePointer($0), socklen_t(sizeofValue($0.memory)))
            }
        }
    }

    /// Converts this address to a `sockaddr_storage` structure.
    public func toStorage() -> sockaddr_storage {
        var storage = sockaddr_storage()
        withSockaddr {
            memcpy(&storage, $0, Int($1))
        }
        return storage
    }

    /// If the SocketAddress is an internet address, unpack into an IP address and port.
    public func toHostAndPort() -> (host: IPAddress, port: UInt16)? {
        switch self {
        case let .Internet(host, port):
            return (host, port)
        }
    }

    /// If the SocketAddress is an internet address, obtains the host.
    public var host: IPAddress? {
        switch self {
        case let .Internet(host, _):
            return host
        }
    }

    /// Treats this SocketAddress as the host of an HTTP server, and convert to a URL.
    ///
    /// - Important:
    ///   The `path` must begin with a slash, e.g. `"/query?t=1"`.
    public func toURL(path: String, scheme: String = "http") -> NSURL? {
        switch self {
        case .Internet:
            return NSURL(string: "\(scheme)://\(stringValue)\(path)")
        }
    }

    public var hashValue: Int {
        switch self {
        case let .Internet(host, port):
            return 0 |+> host |+> port
        }
    }

    /// Obtains the socket address family (e.g. AF_INET).
    public var family: Int32 {
        switch self {
        case let .Internet(host, _):
            return host.family
        }
    }
}

public func ==(lhs: SocketAddress, rhs: SocketAddress) -> Bool {
    switch (lhs, rhs) {
    case let (.Internet(lh, lp), .Internet(rh, rp)):
        return lp == rp && lh == rh
    }
}
