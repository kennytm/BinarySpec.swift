
import Foundation

// MARK: - SliceQueue

// Note that ArraySlice's startIndex is usually not 0, unlike what the documentation said.

/// Stores a queue of `ArraySlice`s.
public struct SliceQueue<T: Equatable>: Equatable {
    private var slices: [ArraySlice<T>] = []

    /// Construct a new queue from an array of slices.
    public init(_ slices: [ArraySlice<T>]) {
        self.slices = slices
    }

    /// The total number of elements contained by this queue.
    ///
    /// - Complexity:
    ///   O(N), where N is the number of slices.
    public var length: Int {
        return slices.reduce(0) { $0 + $1.count }
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
    public mutating func removeFirst(count: Int) -> SliceQueue? {
        guard !slices.isEmpty else { return nil }

        assert(count > 0)

        let firstSlice = slices[0]

        // Handle the common case where the first slice is long enough.
        switch count {
        case 0 ..< firstSlice.count:
            let splitIndex = firstSlice.startIndex.advancedBy(count)
            let removedPart = SliceQueue([firstSlice.prefixUpTo(splitIndex)])
            slices[0] = firstSlice.suffixFrom(splitIndex)
            return removedPart

        case firstSlice.count:
            let removedPart = SliceQueue([firstSlice])
            slices.removeFirst()
            return removedPart

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

                return SliceQueue(removedSlices)

            case currentLength:
                let removedSlices = Array(slices.prefixThrough(i))
                slices.removeFirst(i + 1)
                return SliceQueue(removedSlices)

            default:
                continue
            }
        }

        return nil
    }
}

/// Extends an array slice to the end of the queue.
///
/// - Complexity:
///   O(1).
public func +=<T>(inout queue: SliceQueue<T>, slice: ArraySlice<T>) {
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

