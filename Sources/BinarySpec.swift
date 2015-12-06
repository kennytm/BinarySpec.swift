
import Foundation

// MARK: - Partial

/// Represents the result of reading from a partial data stream.
public enum Partial<T: Equatable>: Equatable {
    /// Reading is succesful. The associated member contains the reading result.
    case Done(T)

    /// Not enough data to read. The associated member provides at least how many more bytes are
    /// needed to complete the read.
    case Incomplete(requesting: Int)
}

public func ==<T>(left: Partial<T>, right: Partial<T>) -> Bool {
    switch (left, right) {
    case let (.Done(l), .Done(r)):
        return l == r
    case let (.Incomplete(l), .Incomplete(r)):
        return l == r
    default:
        return false
    }
}


// MARK: - SliceQueue

// Note that ArraySlice's startIndex is usually not 0, unlike what the documentation said.

/// Stores a queue of `ArraySlice`s.
public struct SliceQueue<T: Equatable>: Equatable {
    private var slices: [ArraySlice<T>] = []

    /// Construct a new queue from an array of slices.
    ///
    /// - Precondition:
    ///   All slices are not empty.
    public init(_ slices: [ArraySlice<T>]) {
        for slice in slices {
            assert(!slice.isEmpty)
        }
        self.slices = slices
    }

    /// The total number of elements contained by this queue.
    ///
    /// - Complexity:
    ///   O(N), where N is the number of slices.
    public var length: Int {
        return slices.reduce(0) { $0 + $1.count }
    }

    /// Whether the queue contains any data.
    ///
    /// - Complexity:
    ///   O(1).
    public var isEmpty: Bool {
        return slices.isEmpty
    }

    /// Removes the first `count` elements from this queue.
    ///
    /// - Returns:
    ///   The list of slices containing the removed elements. If the `count` is longer than the
    ///   `length` of this queue, the return value is `nil`, and this queue remains unmodified.
    ///
    /// - Precondition:
    ///   count > 0
    ///
    /// - Postcondition:
    ///   (return.length == count || return == nil) && (return?.length + self.length == old.length)
    ///
    /// - Complexity:
    ///   O(N), where N is the number of slices.
    public mutating func removeFirst(count: Int) -> Partial<SliceQueue> {
        guard !slices.isEmpty else { return .Incomplete(requesting: count) }

        assert(count > 0)

        let firstSlice = slices[0]

        // Handle the common case where the first slice is long enough.
        switch count {
        case 0 ..< firstSlice.count:
            let splitIndex = firstSlice.startIndex.advancedBy(count)
            let removedPart = SliceQueue([firstSlice.prefixUpTo(splitIndex)])
            slices[0] = firstSlice.suffixFrom(splitIndex)
            return .Done(removedPart)

        case firstSlice.count:
            let removedPart = SliceQueue([firstSlice])
            slices.removeFirst()
            return .Done(removedPart)

        default:
            break
        }

        var currentLength = 0
        for (i, slice) in slices.enumerate() {
            currentLength += slice.count

            switch count {
            case 0 ..< currentLength:
                var removedSlices = Array(slices.prefixThrough(i))
                slices.removeFirst(i)

                let splitPosition = slice.endIndex.advancedBy(count - currentLength)
                let firstPartialSlice = slice.prefixUpTo(splitPosition)
                let secondPartialSlice = slice.suffixFrom(splitPosition)

                removedSlices[removedSlices.endIndex.predecessor()] = firstPartialSlice
                slices[0] = secondPartialSlice

                return .Done(SliceQueue(removedSlices))

            case currentLength:
                let removedSlices = Array(slices.prefixThrough(i))
                slices.removeFirst(i + 1)
                return .Done(SliceQueue(removedSlices))

            default:
                continue
            }
        }

        return .Incomplete(requesting: count - currentLength)
    }

    /// Combines all elements in this queue into a single array slice.
    public func asArraySlice() -> ArraySlice<T> {
        switch slices.count {
        case 0:
            return ArraySlice()
        case 1:
            return slices[0]
        default:
            return slices.dropFirst().reduce(slices.first!, combine: +)
        }
    }
}

/// Extends an array slice to the end of the queue.
///
/// - Complexity:
///   O(1).
public func +=<T>(inout queue: SliceQueue<T>, slice: ArraySlice<T>) {
    assert(!slice.isEmpty)
    queue.slices.append(slice)
}

/// Extends another queue to the end of this queue.
///
/// - Complexity:
///   O(N).
public func +=<T>(inout queue: SliceQueue<T>, other: SliceQueue<T>) {
    queue.slices += other.slices
}

/// Compares if the content of the two queues are equal. How the data are sliced up do not affect
/// the comparison result, e.g. `[[1, 2], 3] == [[1], [2, 3]]`.
///
/// - Complexity:
///   O(N).
public func ==<T>(left: SliceQueue<T>, right: SliceQueue<T>) -> Bool {
    // TODO: Implementation is too complex.
    var leftIter = left.slices.generate()
    var rightIter = right.slices.generate()
    var leftSlice = leftIter.next()
    var rightSlice = rightIter.next()
    while true {
        var leftExhausted = false
        var rightExhausted = false

        if leftSlice == nil {
            leftSlice = leftIter.next()
            leftExhausted = (leftSlice == nil)
        }
        if rightSlice == nil {
            rightSlice = rightIter.next()
            rightExhausted = (rightSlice == nil)
        }

        switch (leftExhausted, rightExhausted) {
        case (true, true):
            return true
        case (false, false):
            break
        default:
            return false
        }

        guard let l = leftSlice else { abort() }
        guard let r = rightSlice else { abort() }

        let isLeftShorter = l.count < r.count

        let (short, long) = isLeftShorter ? (l, r) : (r, l)
        let longSplitIndex = long.startIndex.advancedBy(short.count)
        let longPrefix = long.prefixUpTo(longSplitIndex)

        if short != longPrefix {
            return false
        }

        let longSuffix: ArraySlice<T>?
        longSuffix = (longSplitIndex == long.endIndex) ? nil : long.suffixFrom(longSplitIndex)
        if isLeftShorter {
            leftSlice = nil
            rightSlice = longSuffix
        } else {
            leftSlice = longSuffix
            rightSlice = nil
        }
    }
}

// MARK: - IntSpec

/** Specification for an integer type. This structure defines how an integer is encoded in binary. */
public struct IntSpec {
    /** Length of integer. Normally should be 1, 2, 4 or 8. */
    public let length: Int

    /** Endian of the integer when encoded. */
    public let endian: CFByteOrder

    /** Specification of a byte (8-bit unsigned integer). */
    public static let Byte = IntSpec(length: 1, endian: NSHostByteOrder())
    /** Specification of a big-endian 16-bit unsigned integer. */
    public static let UInt16BE = IntSpec(length: 2, endian: NS_BigEndian)
    /** Specification of a little-endian 16-bit unsigned integer. */
    public static let UInt16LE = IntSpec(length: 2, endian: NS_LittleEndian)
    /** Specification of a big-endian 32-bit unsigned integer. */
    public static let UInt32BE = IntSpec(length: 4, endian: NS_BigEndian)
    /** Specification of a little-endian 32-bit unsigned integer. */
    public static let UInt32LE = IntSpec(length: 4, endian: NS_LittleEndian)
    /** Specification of a big-endian 64-bit unsigned integer. */
    public static let UInt64BE = IntSpec(length: 8, endian: NS_BigEndian)
    /** Specification of a little-endian 64-bit unsigned integer. */
    public static let UInt64LE = IntSpec(length: 8, endian: NS_LittleEndian)

    /// Encodes an integer. The encode result will be supplied to the closure (the result will be
    /// invalidated after the closure exits).
    public func encode<R>(integer: UIntMax, closure: UnsafeBufferPointer<UInt8> throws -> R) rethrows -> R {
        var prepared: UIntMax
        switch endian {
        case NS_BigEndian:
            let bitShift = (sizeof(UIntMax) - length) * 8
            prepared = (integer << UIntMax(bitShift)).bigEndian
            break
        default:
            prepared = integer.littleEndian
            break
        }
        return try withUnsafePointer(&prepared) { ptr in
            let buffer = UnsafeBufferPointer<UInt8>(start: UnsafePointer(ptr), count: length)
            return try closure(buffer)
        }
    }
}

extension ArraySlice {
    /// Decodes the content of this queue as integer using the given specification.
    ///
    /// - Precondition:
    ///   self.count * sizeof(Generator.Element) >= spec.length
    public func toUIntMax(spec: IntSpec) -> UIntMax {
        var result: UIntMax = 0
        withUnsafeBufferPointer { buffer in
            let byteLength = buffer.count * sizeof(Generator.Element.self)
            assert(byteLength >= spec.length)

            memcpy(&result, buffer.baseAddress, spec.length)

            switch spec.endian {
            case NS_BigEndian:
                let bitShift = (sizeof(UIntMax) - spec.length) * 8
                result = UIntMax(bigEndian: result) >> UIntMax(bitShift)
                break
            default:
                result = UIntMax(littleEndian: result)
                break
            }
        }
        return result
    }
}
