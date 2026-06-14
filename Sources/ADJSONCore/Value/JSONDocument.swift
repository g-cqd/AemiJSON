/// An immutable parsed JSON document: the original UTF-8 input plus the tape. Values are
/// materialized lazily through `JSON` views, so the document holds no decoded Swift objects.
/// Immutable after construction, hence `Sendable`.
public final class JSONDocument: Sendable {
    /// Owned UTF-8 input as `[UInt8]`. `String`/`Data` inputs are copied into this buffer at the
    /// parse boundary (the umbrella `ADJSON.parse(_:Data)` overload performs the copy); a `[UInt8]`
    /// input keeps its single existing copy. Exposes contiguous bytes via `withBytePointer`.
    package enum Backing: Sendable {
        case bytes([UInt8])

        @inline(__always) var count: Int {
            switch self {
            case .bytes(let b): return b.count
            }
        }
    }

    package let backing: Backing
    package let tape: ContiguousArray<UInt64>
    /// True when the parse guaranteed unique object keys (the `.throwError` duplicate-key strategy
    /// rejects duplicates), which lets key lookups stop at the first match instead of scanning to
    /// the last (the `.useLast` default requires the full scan).
    package let keysAreUnique: Bool

    package init(backing: Backing, tape: ContiguousArray<UInt64>, keysAreUnique: Bool = false) {
        self.backing = backing
        self.tape = tape
        self.keysAreUnique = keysAreUnique
    }

    /// The root value of the document.
    public var root: JSON { JSON(doc: self, index: 0) }
}
