// swift-nio interop for ADJSON: parse a `ByteBuffer` with no copy, and serialize JSON into a
// `ByteBuffer` sink. A superset module — it re-exports the Foundation-free `ADJSONCore` engine, so
// `import ADJSONNIO` gives a server everything it needs (`ADJSON.parse`, `JSON`, `JSONValue`,
// query/mutation) plus the NIO bridge, without pulling Foundation or swift-syntax. swift-nio enters
// the dependency graph only here (the `ADJSON_NIO`-gated product), never in the base products.

@_exported import ADJSONCore
public import NIOCore
// Re-export OrderedCollections too (as the umbrella `ADJSON` module does), so `import ADJSONNIO`
// consumers can build / pattern-match `JSONValue.object` payloads without a separate import.
@_exported import OrderedCollections

extension ADJSON {
    /// Parse the readable bytes of a `ByteBuffer` into an immutable document **without copying** — the
    /// document borrows the buffer's storage in place. The buffer's reader index is unchanged.
    ///
    /// Safe and `Sendable`: `ByteBuffer` is a copy-on-write value type, so the retained copy the
    /// document holds keeps its bytes stable for the document's lifetime even if the caller mutates
    /// theirs (a write triggers a copy). This mirrors `parse(_ source: some ByteSource & Sendable)`.
    public static func parse(
        _ buffer: ByteBuffer, options: JSONParseOptions = .strict
    ) throws(JSONError) -> JSONDocument {
        try parse(NIOByteBufferSource(buffer), options: options)
    }
}

/// A ``ByteSource`` over a `ByteBuffer`'s readable bytes — zero copy, read in place.
///
/// `@unchecked Sendable`: the wrapped `ByteBuffer` is value-semantic (CoW) and only ever read here,
/// so sharing it read-only across the concurrent decoder's tasks is sound (any caller mutation copies
/// first and cannot disturb this retained value).
struct NIOByteBufferSource: ByteSource, @unchecked Sendable {
    let buffer: ByteBuffer
    init(_ buffer: ByteBuffer) { self.buffer = buffer }
    func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try buffer.withUnsafeReadableBytes(body)
    }
}

extension ByteBuffer {
    /// Append `value` serialized to UTF-8 JSON (compact by default; pass `options` for pretty / sorted
    /// / number-format / escaping), advancing the writer index.
    public mutating func writeJSON(_ value: JSONValue, options: JSONEncodingOptions = .rfc8259) throws {
        writeBytes(try value.encodedBytes(options: options))
    }

    /// Append a lazy ``JSON`` cursor serialized to UTF-8 JSON — no `JSONValue` materialization.
    public mutating func writeJSON(_ json: JSON, options: JSONEncodingOptions = .rfc8259) throws {
        writeBytes(try json.encodedBytes(options: options))
    }
}
