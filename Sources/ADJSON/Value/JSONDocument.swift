public import Foundation

/// An immutable parsed JSON document: the original UTF-8 input plus the tape. Values are
/// materialized lazily through `JSON` views, so the document holds no decoded Swift objects.
/// Immutable after construction, hence `Sendable`.
public final class JSONDocument: Sendable {
    /// Owned UTF-8 input. A `Data` input is retained as-is (no `[UInt8]` copy); `[UInt8]` / `String`
    /// input keeps its single existing copy. Both expose contiguous bytes via `withBytePointer`.
    @usableFromInline
    enum Backing: Sendable {
        case bytes([UInt8])
        case data(Data)

        @inline(__always) var count: Int {
            switch self {
            case .bytes(let b): return b.count
            case .data(let d): return d.count
            }
        }
    }

    @usableFromInline let backing: Backing
    @usableFromInline let tape: [UInt64]

    @usableFromInline
    init(backing: Backing, tape: [UInt64]) {
        self.backing = backing
        self.tape = tape
    }

    /// The root value of the document.
    public var root: JSON { JSON(doc: self, index: 0) }
}
