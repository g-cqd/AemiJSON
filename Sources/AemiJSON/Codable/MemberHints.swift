import AemiJSONCore

// Ordered member lookup (roadmap 0002). `Decodable` asks for an object's keys in declaration order, usually the document's own order, so a
// keyed container's next key is most often the member after the one it found last. A container whose object has distinct keys keeps
// that place in a hint, and a lookup starts there: in order, each key is found within two comparisons instead of after a scan of the
// whole object.
//
// The keys must be known distinct, because a repeated key resolves to its last spelling and only a full scan finds that. A document parsed
// with `.throwError` has distinct keys by construction; otherwise the container checks once, when it is opened, by hashing the raw key
// bytes. An escaped key gives up the check (two spellings can be one key), and so does an object under `minimumMembers`, where the scan
// is cheaper than the check.
//
// Hints live in the context, inline (no allocation), in a small ring indexed by decode depth: a keyed container is a value the protocol never lets mutate, and
// nested containers open at deeper depths, so a parent's hint survives its children. A hint names its object, so one overwritten by a
// sibling or a `nestedContainer` at the same depth is only ignored, and the lookup falls back to the full scan.

extension DecodeContext {
    /// Objects with fewer members are scanned: the full scan is at most 9 comparisons.
    static let minimumMembers = 4
    /// Ring slots, one per nesting depth modulo this.
    static let hintSlots = 8
    /// Objects of up to this many members check their keys in the context's inline table, without allocating.
    static let inlineMembers = 32

    /// The hint slot of a keyed container opened now over `obj`, or -1 when lookups in it scan from the first member.
    func openMemberHint(of obj: Int) -> Int {
        let c = count(obj)
        guard c >= Self.minimumMembers, tapeCount <= Int(Int32.max), keysAreUnique || membersAreDistinct(obj, count: c)
        else { return -1 }
        let slot = decodeDepth & (Self.hintSlots - 1)
        hintObject[slot] = obj
        hintKey[slot] = obj + 1
        hintOrdinal[slot] = 0
        return slot
    }

    /// The value index for `key` in the object at `obj`, starting from the hint in `hintSlot` and wrapping once; `nil` when the hint has
    /// been replaced, so the caller scans. On a hit the hint moves to the member found, so a key read twice in a row (as
    /// `decodeIfPresent` does) is found at once, and the next key in order one comparison later.
    func hintedMemberValueIndex(of obj: Int, key: String, slot hintSlot: Int) -> Int?? {
        guard hintObject[hintSlot] == obj else { return nil }
        let c = Slot.count(slot(obj))
        var i = hintKey[hintSlot]
        var ordinal = hintOrdinal[hintSlot]
        for _ in 0 ..< c {
            if ordinal == c {
                i = obj + 1
                ordinal = 0
            }
            if keyMatches(at: i, key) {
                hintKey[hintSlot] = i
                hintOrdinal[hintSlot] = ordinal
                return .some(i + 1)
            }
            i = uncheckedNextIndex(after: i + 1)
            ordinal += 1
        }
        return .some(nil)
    }

    /// Whether the `c` members of the object at `obj` have pairwise different keys, comparing raw bytes; `false` when a key is escaped.
    /// Open addressing over the keys' hashes, in the inline table up to `inlineMembers` and in a reused heap table past it.
    private func membersAreDistinct(_ obj: Int, count c: Int) -> Bool {
        if c <= Self.inlineMembers {
            inlineKeyTable = SIMD64(repeating: -1)
            return insertKeys(of: obj, count: c, mask: 63) { probe in
                inlineKeyTable[probe]
            } store: { probe, key in
                inlineKeyTable[probe] = key
            }
        }
        var capacity = 128
        while capacity < 2 * c { capacity <<= 1 }
        let table: UnsafeMutablePointer<Int32>
        if let current = keyTable, capacity <= keyTableCapacity {
            table = current
        } else {
            keyTable?.deallocate()
            table = .allocate(capacity: capacity)
            keyTable = table
            keyTableCapacity = capacity
        }
        table.update(repeating: -1, count: capacity)
        return insertKeys(of: obj, count: c, mask: capacity - 1) {
            table[$0]
        } store: {
            table[$0] = $1
        }
    }

    @inline(__always) private func insertKeys(
        of obj: Int, count c: Int, mask: Int, load: (Int) -> Int32, store: (Int, Int32) -> Void
    ) -> Bool {
        var i = obj + 1
        for _ in 0 ..< c {
            let ks = uncheckedSlot(i)
            if Slot.flags(ks) & 1 == 1 { return false }
            let koff = Slot.low(ks)
            let klen = Slot.length(ks)
            assertBytes(koff, klen)
            var probe = Self.keyHash(bytes + koff, klen) & mask
            while true {
                let other = Int(load(probe))
                if other < 0 { break }
                let os = uncheckedSlot(other)
                if Slot.length(os) == klen, Self.equalBytes(bytes + Slot.low(os), bytes + koff, klen) { return false }
                probe = (probe + 1) & mask
            }
            store(probe, Int32(truncatingIfNeeded: i))
            i = uncheckedNextIndex(after: i + 1)
        }
        return true
    }

    /// FNV-1a over the key's bytes, folded.
    @inline(__always) private static func keyHash(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for k in 0 ..< n { h = (h ^ UInt64(p[k])) &* 0x100_0000_01b3 }
        return Int(truncatingIfNeeded: h ^ (h >> 29))
    }

    @inline(__always) private static func equalBytes(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ n: Int)
        -> Bool
    {
        for k in 0 ..< n where a[k] != b[k] { return false }
        return true
    }
}
