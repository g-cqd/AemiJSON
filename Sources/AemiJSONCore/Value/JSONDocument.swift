/// An immutable parsed JSON document: the original UTF-8 input plus the tape. Values are
/// materialized lazily through `JSON` views, so the document holds no decoded Swift objects.
/// Immutable after construction, hence `Sendable`.
public final class JSONDocument: Sendable {
    /// Owned UTF-8 input. A `[UInt8]` input keeps its single existing copy (`.bytes`); a `String`
    /// input is copied once into a `[UInt8]` at the parse boundary. A ``ByteSource`` owner (e.g.
    /// `Data`) is **retained in place** (`.source`) and read without a copy, together with the byte
    /// count the parse validated, so no later borrow has to trust the source's length again.
    /// Exposes contiguous bytes via `withBytePointer`.
    package enum Backing: Sendable {
        case bytes([UInt8])
        case source(any ByteSource & Sendable, count: Int)

        @inline(__always) var count: Int {
            switch self {
                case .bytes(let b): return b.count
                case .source(_, let count): return count
            }
        }
    }

    package let backing: Backing
    package let tape: ContiguousArray<UInt64>
    /// True when the parse guaranteed unique object keys (the `.throwError` duplicate-key strategy
    /// rejects duplicates), which lets key lookups stop at the first match instead of scanning to
    /// the last (the `.useLast` default requires the full scan).
    package let keysAreUnique: Bool
    /// True when parsed in JSON5 mode, so escaped string/key bytes are decoded with the JSON5 escape
    /// set (`\x`, `\v`, `\0`, line continuations, …) rather than the strict JSON set.
    package let isJSON5: Bool
    /// PROTOTYPE (raw-subtree bytes): container tape index → packed inclusive source span
    /// (`open << 32 | close`), recorded by the parser so ``JSON/withRawJSONBytes(_:)`` can borrow a
    /// container's raw source text zero-copy. Empty for documents built without a parse.
    package let containerSpans: [Int: UInt64]

    package init(
        backing: Backing, tape: ContiguousArray<UInt64>, keysAreUnique: Bool = false, isJSON5: Bool = false,
        containerSpans: [Int: UInt64] = [:]
    ) {
        self.backing = backing
        self.tape = tape
        self.keysAreUnique = keysAreUnique
        self.isJSON5 = isJSON5
        self.containerSpans = containerSpans
    }

    /// The root value of the document.
    public var root: JSON { JSON(doc: self, index: 0) }
}
