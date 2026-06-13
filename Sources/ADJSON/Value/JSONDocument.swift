/// An immutable parsed JSON document: the original UTF-8 bytes plus the tape.
/// Values are materialized lazily through `JSON` views, so the document itself
/// holds no decoded Swift objects. Immutable after construction, hence `Sendable`.
public final class JSONDocument: Sendable {
    @usableFromInline let bytes: [UInt8]
    @usableFromInline let tape: [UInt64]

    @usableFromInline
    init(bytes: [UInt8], tape: [UInt64]) {
        self.bytes = bytes
        self.tape = tape
    }

    /// The root value of the document.
    public var root: JSON { JSON(doc: self, index: 0) }
}
