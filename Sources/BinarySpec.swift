
import Foundation

// MARK: - Partial

public struct IncompleteError: ErrorType {
    public let requestedCount: Int

    public func asPartial<T>() -> Partial<T> {
        return .Incomplete(requesting: requestedCount)
    }
}

/// Represents the result of reading from a partial data stream.
public enum Partial<T: Equatable>: Equatable {
    /// Reading is succesful. The associated member contains the reading result.
    case Ok(T)

    /// Not enough data to read. The associated member provides at least how many more bytes are
    /// needed to complete the read.
    case Incomplete(requesting: Int)

    /// Returns the wrapped object if it is `.Done`. Throws `IncompleteError` if it is `.Incomplete`.
    public func unwrap() throws -> T {
        switch self {
        case let .Ok(a):
            return a
        case let .Incomplete(n):
            throw IncompleteError(requestedCount: n)
        }
    }
}

public func ==<T>(left: Partial<T>, right: Partial<T>) -> Bool {
    switch (left, right) {
    case let (.Ok(l), .Ok(r)):
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
    public init(_ slices: [ArraySlice<T>] = []) {
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
    /// - Postcondition:
    ///   (return.length == count || return == nil) && (return?.length + self.length == old.length)
    ///
    /// - Complexity:
    ///   O(N), where N is the number of slices.
    @warn_unused_result
    public mutating func removeFirst(count: Int) -> Partial<SliceQueue> {
        if count == 0 {
            return .Ok(SliceQueue())
        }

        guard !slices.isEmpty else { return .Incomplete(requesting: count) }

        assert(count > 0)

        let firstSlice = slices[0]

        // Handle the common case where the first slice is long enough.
        switch count {
        case 0 ..< firstSlice.count:
            let splitIndex = firstSlice.startIndex.advancedBy(count)
            let removedPart = SliceQueue([firstSlice.prefixUpTo(splitIndex)])
            slices[0] = firstSlice.suffixFrom(splitIndex)
            return .Ok(removedPart)

        case firstSlice.count:
            let removedPart = SliceQueue([firstSlice])
            slices.removeFirst()
            return .Ok(removedPart)

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

                return .Ok(SliceQueue(removedSlices))

            case currentLength:
                let removedSlices = Array(slices.prefixThrough(i))
                slices.removeFirst(i + 1)
                return .Ok(SliceQueue(removedSlices))

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

    /// Writes the content of this queue into the encoder. The encoder may be called multiple times.
    public func encode(encoder: UnsafeBufferPointer<T> throws -> ()) rethrows -> Int {
        var encodedCount = 0
        for slice in slices {
            try slice.withUnsafeBufferPointer(encoder)
            encodedCount += slice.count
        }
        return encodedCount
    }

    /// Encodes exactly *n* bytes. If the queue is shorter, pad the end with the supplied element. 
    /// If the queue is longer, the result will be truncated.
    ///
    /// The encoder may be called multiple times.
    public func encodeExactly(count: Int, padding: T, encoder: UnsafeBufferPointer<T> throws -> ()) rethrows {
        var encodedCount = 0
        for slice in slices {
            encodedCount += slice.count
            if encodedCount > count {
                let subsliceIndex = slice.endIndex.advancedBy(count - encodedCount)
                let subslice = slice.prefixUpTo(subsliceIndex)
                try subslice.withUnsafeBufferPointer(encoder)
                return
            } else {
                try slice.withUnsafeBufferPointer(encoder)
            }
        }
        if encodedCount < count {
            let paddingArray = [T](count: count - encodedCount, repeatedValue: padding)
            try paddingArray.withUnsafeBufferPointer(encoder)
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
public struct IntSpec: Equatable {
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

    /// Encodes an integer. The encode result will be supplied to the `encoder` (the result will be
    /// invalidated after the closure exits).
    public func encode<R>(integer: UIntMax, encoder: UnsafeBufferPointer<UInt8> throws -> R) rethrows -> R {
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
            return try encoder(buffer)
        }
    }
}

public func ==(left: IntSpec, right: IntSpec) -> Bool {
    return left.length == right.length && left.endian == right.endian
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

// MARK: - BinaryData

/// The parsed binary data.
public indirect enum BinaryData: Equatable {
    /// No data.
    case Empty

    /// An error value that indicates parsing has been stopped at the outermost level. The whole
    /// structure would become invalid since the future length information would be corrupted. The
    /// `.Stop` data is silently hidden inside an `.Until` spec.
    ///
    /// - Parameters:
    ///   - 0: The specification that caused the error.
    ///   - 1: The value in the data stream, if any, which caused the specification to reject it.
    case Stop(BinarySpec, UIntMax)

    /// A parsed integer.
    case Integer(UIntMax)

    /// Raw bytes.
    case Bytes(SliceQueue<UInt8>)

    /// Sequence of more data.
    case Seq([BinaryData])

    /// Whether this is a "stop" data.
    public var isStop: Bool {
        if case .Stop = self {
            return true
        } else {
            return false
        }
    }
}

public func ==(left: BinaryData, right: BinaryData) -> Bool {
    switch (left, right) {
    case (.Empty, .Empty):
        return true
    case let (.Integer(a), .Integer(b)):
        return a == b
    case let (.Bytes(a), .Bytes(b)):
        return a == b
    case let (.Seq(a), .Seq(b)):
        return a == b
    case let (.Stop(a, c), .Stop(b, d)):
        return a == b && c == d
    default:
        return false
    }
}

// MARK: - BinarySpec

/// Type of a variable name.
public typealias VariableName = StaticString

extension VariableName: Hashable {
    public var hashValue: Int {
        return stringValue.hashValue
    }
}

public func ==(left: VariableName, right: VariableName) -> Bool {
    return left.withUTF8Buffer { a in
        right.withUTF8Buffer { b in
            return a.count == b.count && memcmp(a.baseAddress, b.baseAddress, a.count) == 0
        }
    }
}

/// An intermediate error thrown when a `.Stop` spec is encountered.
private struct StopParsingError: ErrorType {
    let spec: BinarySpec
    let value: UIntMax

    func toBinaryData() -> BinaryData {
        return .Stop(spec, value)
    }
}

/// A specification of how a raw binary data stream should be parsed.
public indirect enum BinarySpec: Equatable {
    /// Reads _n_ bytes and ignore the result. Decodes to `BinaryData.Empty`. When encoded, this
    /// field will generate zeros.
    case Skip(Int)

    /// Immediately stop reading this data stream. This will propagate until an `.Until` 
    /// specification.
    case Stop

    /// Integer. Decodes to `BinaryData.Integer`.
    case Integer(IntSpec)

    /// Integer variable. The variable name should be used to define the length of some dynamic
    /// structures later. Decodes to `BinaryData.Integer`.
    ///
    /// - Warning: 
    ///   Refering to a variable before it is defined will cause `fatalError`.
    case Variable(IntSpec, VariableName)

    /// Dynamic bytes. Uses the content of a variable as the length, then reads the corresponding
    /// number of bytes. Decodes to `BinaryData.Bytes`.
    case Bytes(VariableName)

    /// Sequence of sub-specifications. Decodes to `BinaryData.Seq`.
    case Seq([BinarySpec])

    /// Repeated data with a given length. Uses the content of a variable as the length of data,
    /// then repeats the sub-specification until the length runs out. Decodes to `BinaryData.Seq`.
    case Until(VariableName, BinarySpec)

    /// Repeated data with a given count. Then repeats the sub-specification exactly *n* times, 
    /// where *n* is given by the variable. Decodes to `BinaryData.Seq`.
    case Repeat(VariableName, BinarySpec)

    /// Enumerated cases.
    ///
    /// - Parameters:
    ///   - selector: 
    ///     The variable that introduces the case to select.
    ///   - cases:
    ///     How to react according to different selectors. 
    ///   - default:
    ///     The default case when none of the cases match. Supply `.Stop` here if no default case
    ///     is expected.
    case Switch(selector: VariableName, cases: [UIntMax: BinarySpec], `default`: BinarySpec)
}

public func ==(left: BinarySpec, right: BinarySpec) -> Bool {
    switch (left, right) {
    case let (.Skip(a), .Skip(b)):
        return a == b
    case (.Stop, .Stop):
        return true
    case let (.Integer(a), .Integer(b)):
        return a == b
    case let (.Variable(a, c), .Variable(b, d)):
        return a == b && c == d
    case let (.Bytes(a), .Bytes(b)):
        return a == b
    case let (.Seq(a), .Seq(b)):
        return a == b
    case let (.Until(a, c), .Until(b, d)):
        return a == b && c == d
    case let (.Repeat(a, c), .Repeat(b, d)):
        return a == b && c == d
    case let (.Switch(a, c, e), .Switch(b, d, f)):
        return a == b && c == d && e == f
    default:
        return false
    }
}

// MARK: - IncompleteBinaryData

/// An intermediate state when a BinarySpec is being parsed into BinaryData.
private indirect enum IncompleteBinaryData {
    /// Reading not started yet.
    case Prepared(BinarySpec)

    /// Everything has been read.
    case Done(BinaryData)

    /// Partial sequence.
    case PartialSeq(done: [BinaryData], remaining: ArraySlice<BinarySpec>)

    /// Partial specification repetition.
    case PartialRepeat(done: [BinaryData], remaining: UIntMax, spec: BinarySpec)

    /// Append a data to a partial sequence. Fails if this is not `.Partial*`.
    func fillHole(data: BinaryData) -> IncompleteBinaryData {
        switch self {
        case let .PartialSeq(done, remaining):
            var newDone = done
            newDone.append(data)
            return .PartialSeq(done: newDone, remaining: remaining)

        case let .PartialRepeat(done, remaining, spec):
            var newDone = done
            newDone.append(data)
            return .PartialRepeat(done: newDone, remaining: remaining, spec: spec)

        default:
            fatalError("Should not fill in \(data) into \(self)")
        }
    }

    /// Obtains the data in stored in this structure, even if not all of them are complete.
    var data: BinaryData {
        switch self {
        case .Prepared:
            return .Empty
        case let .Done(b):
            return b
        case let .PartialSeq(done, _):
            return .Seq(done)
        case let .PartialRepeat(done, _, _):
            return .Seq(done)
        }
    }
}

// MARK: - BinaryParser

private enum BinaryParserNextAction {
    case Continue
    case Done
}

/// A parser that reads a byte stream, and decodes into BinaryData, according to the rules in a 
/// provided BinarySpec.
public class BinaryParser {
    private var incompleteDataStack: [IncompleteBinaryData]
    private var variables: [VariableName: UIntMax] = [:]
    private var queue = SliceQueue<UInt8>()

    /// Initialize the parser using a specification.
    public init(_ spec: BinarySpec) {
        incompleteDataStack = [.Prepared(spec)]
    }

    /// Provide more data to the parser.
    public func supply(data: SliceQueue<UInt8>) {
        queue += data
    }

    /// Provide more data to the parser.
    public func supply(data: ArraySlice<UInt8>) {
        queue += data
    }

    /// Provide more data to the parser.
    public func supply(data: [UInt8]) {
        queue += ArraySlice(data)
    }

    /// Obtains the remaining bytes not yet parsed.
    public var remaining: SliceQueue<UInt8> {
        return queue
    }

    /// Performs a parsing step using as many bytes available as possible.
    ///
    /// - Returns:
    ///   On succeed, returns `.Ok` containing the parsed data. If there is not enough bytes
    ///   available, returns `.Incomplete` indicating at least how much bytes are needed to proceed
    ///   to the next step.
    @warn_unused_result
    public func next() -> Partial<BinaryData> {
        while true {
            do {
                switch try step() {
                case .Ok(.Done):
                    assert(incompleteDataStack.count == 1)
                    return .Ok(incompleteDataStack.last!.data)
                case .Ok(.Continue):
                    continue
                case let .Incomplete(count):
                    return .Incomplete(requesting: count)
                }
            } catch let e as StopParsingError {
                let errorData = e.toBinaryData()
                incompleteDataStack = [.Done(errorData)]
                return .Ok(errorData)
            } catch {
                fatalError("Unexepected error being thrown")
            }
        }
    }

    /// Parses all the bytes available. If the bytes are long enough to provide multiple BinaryData,
    /// all of them will be returned from this method.
    public func parseAll() -> [BinaryData] {
        let initialStack = incompleteDataStack

        assert(initialStack.count == 1)

        var result: [BinaryData] = []
        while case let .Ok(data) = next() where !data.isStop {
            result.append(data)
            incompleteDataStack = initialStack
            variables = [:]
        }
        return result
    }

    /// Performs an atomic parsing step.
    @warn_unused_result
    private func step() throws -> Partial<BinaryParserNextAction> {
        let lastState = incompleteDataStack.removeLast()

        do {
            switch lastState {
            case .Done:
                assert(incompleteDataStack.isEmpty)
                incompleteDataStack.append(lastState)
                return .Ok(.Done)

            case let .Prepared(.Skip(n)):
                try queue.removeFirst(n).unwrap()
                return .Ok(pushState(.Empty))

            case let .Prepared(.Integer(spec)):
                let data = try queue.removeFirst(spec.length).unwrap()
                let integer = data.asArraySlice().toUIntMax(spec)
                return .Ok(pushState(.Integer(integer)))

            case let .Prepared(.Variable(spec, name)):
                let data = try queue.removeFirst(spec.length).unwrap()
                let integer = data.asArraySlice().toUIntMax(spec)
                variables[name] = integer
                return .Ok(pushState(.Integer(integer)))

            case let .Prepared(.Bytes(name)):
                let length = Int(variables[name]!)
                let data = try queue.removeFirst(length).unwrap()
                return .Ok(pushState(.Bytes(data)))

            case let .Prepared(.Seq(specs)):
                if let firstSpec = specs.first {
                    let remainingSpecs = specs.suffixFrom(specs.startIndex.successor())
                    incompleteDataStack.append(.PartialSeq(done: [], remaining: remainingSpecs))
                    incompleteDataStack.append(.Prepared(firstSpec))
                    return .Ok(.Continue)
                } else {
                    return .Ok(pushState(.Seq([])))
                }

            case let .PartialSeq(done, remaining):
                if let firstSpec = remaining.first {
                    let remainingSpecs = remaining.suffixFrom(remaining.startIndex.successor())
                    incompleteDataStack.append(.PartialSeq(done: done, remaining: remainingSpecs))
                    incompleteDataStack.append(.Prepared(firstSpec))
                    return .Ok(.Continue)
                } else {
                    return .Ok(pushState(.Seq(done)))
                }

            case let .Prepared(.Repeat(name, spec)):
                let count = variables[name]!
                incompleteDataStack.append(.PartialRepeat(done: [], remaining: count, spec: spec))
                incompleteDataStack.append(.Prepared(spec))
                return .Ok(.Continue)

            case let .PartialRepeat(done, remaining, spec):
                if remaining > 0 {
                    incompleteDataStack.append(.PartialRepeat(done: done, remaining: remaining - 1, spec: spec))
                    incompleteDataStack.append(.Prepared(spec))
                    return .Ok(.Continue)
                } else {
                    return .Ok(pushState(.Seq(done)))
                }

            case let .Prepared(.Switch(name, cases, def)):
                let selector = variables[name]!
                let chosen = cases[selector] ?? def
                if case .Stop = chosen {
                    let spec = BinarySpec.Switch(selector: name, cases: cases, `default`: def)
                    throw StopParsingError(spec: spec, value: selector)
                } else {
                    incompleteDataStack.append(.Prepared(chosen))
                    return .Ok(.Continue)
                }

            case let .Prepared(.Until(name, spec)):
                let length = Int(variables[name]!)
                let data = try queue.removeFirst(length).unwrap()
                let subparser = BinaryParser(spec)
                subparser.supply(data)
                let result = subparser.parseAll()
                return .Ok(pushState(.Seq(result)))

            case .Prepared(.Stop):
                // No need to restore the stack, we will abandon everything anyway.
                throw StopParsingError(spec: .Stop, value: 0)
            }
        } catch let e as IncompleteError {
            incompleteDataStack.append(lastState)
            return e.asPartial()
        }
    }

    /// Fill in any completed "BinaryData" hole in the partial state.
    private func pushState(data: BinaryData) -> BinaryParserNextAction {
        if incompleteDataStack.isEmpty {
            incompleteDataStack.append(.Done(data))
            return .Done
        } else {
            let lastIndex = incompleteDataStack.endIndex.predecessor()
            let lastItem = incompleteDataStack[lastIndex]
            let filledItem = lastItem.fillHole(data)
            incompleteDataStack[lastIndex] = filledItem
            return .Continue
        }
    }
}
