/// The raw source spans of a document's containers, recorded by the parser under
/// ``JSONParseOptions/recordsContainerSpans`` for ``JSON/withRawJSONBytes(_:)``. Containers open in
/// tape order, so each entry is appended already sorted by tape index and a lookup is a binary
/// search: no hashing, and two flat arrays instead of a hash table.
package struct ContainerSpans: Sendable {
    /// Tape index of each recorded container, ascending.
    private var tapeIndices: ContiguousArray<UInt32> = []
    /// The matching byte span, inclusive on both ends and packed as `open << 32 | close`. Offsets and
    /// tape indices fit 32 bits: the parser rejects input over 4 GiB and tapes over 2^32 slots.
    private var packed: ContiguousArray<UInt64> = []

    package init() {}

    /// Reserves room for `count` containers, so recording a typical document does not regrow.
    mutating func reserveCapacity(_ count: Int) {
        tapeIndices.reserveCapacity(count)
        packed.reserveCapacity(count)
    }

    /// Records a container whose opening bracket sits at byte `offset` and whose slot is at
    /// `tapeIndex`, returning the entry `close(_:at:)` completes.
    mutating func open(tapeIndex: Int, at offset: Int) -> Int {
        tapeIndices.append(UInt32(truncatingIfNeeded: tapeIndex))
        packed.append(UInt64(UInt32(truncatingIfNeeded: offset)) << 32)
        return packed.count - 1
    }

    /// Completes `entry` with the byte offset of the container's closing bracket.
    mutating func close(_ entry: Int, at offset: Int) {
        packed[entry] |= UInt64(UInt32(truncatingIfNeeded: offset))
    }

    /// The source bytes of the container whose slot is at `tapeIndex`, from its opening bracket
    /// through its closing one, or nil when no span was recorded for it.
    package func span(ofContainerAt tapeIndex: Int) -> ClosedRange<Int>? {
        guard tapeIndex >= 0, tapeIndex <= Int(UInt32.max) else { return nil }
        let target = UInt32(tapeIndex)
        var low = 0
        var high = tapeIndices.count
        while low < high {
            let mid = (low + high) / 2
            if tapeIndices[mid] < target { low = mid + 1 } else { high = mid }
        }
        guard low < tapeIndices.count, tapeIndices[low] == target else { return nil }
        let span = packed[low]
        return Int(span >> 32) ... Int(span & 0xFFFF_FFFF)
    }
}
