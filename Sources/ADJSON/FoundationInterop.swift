import ADJSONCore
public import Foundation

// Foundation interop: the `Data`-based conveniences that mirror Foundation's JSON API, layered on
// top of the Foundation-free `ADJSONCore` engine. Keeping these here is what lets the core stay
// dependency-free while `import ADJSON` consumers keep the familiar `Data`-returning surface.
//
// `Data` holds its bytes contiguously with value semantics, so it conforms to the core's
// ``ByteSource`` and can be parsed **zero-copy** via the generic `parse(_:some ByteSource & Sendable)`
// entry — the document retains the `Data` and reads it in place (copy-on-write keeps the borrowed
// bytes stable if the caller mutates their copy afterward).
//
// The default `parse(_:Data)` deliberately keeps the *copy* path, though. Measurement showed
// zero-copy is a wash on parse throughput — the one input copy is negligible
// against the single-pass scan — while it *regresses* every repeated lazy read (`json.a.b.string`,
// `JSONValue(parsing:)`) by ~20%, because each `withBytePointer` then dispatches through the
// `any ByteSource` existential rather than a directly-inlined `[UInt8]` buffer borrow. So the
// default stays on the fast lazy path; reach for the `ByteSource` overload only when the access
// pattern is decode-once / few-field (no per-value dispatch) and skipping the copy matters (very
// large inputs, memory pressure).

extension Data: ByteSource {
    public func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try withUnsafeBytes(body)
    }
}

extension ADJSON {
    /// Parse UTF-8 `Data` into an immutable, lazily-navigable document. Copies the input once into
    /// the document's owned buffer, which keeps lazy navigation on the fast inlined path; for a
    /// zero-copy alternative (at the cost of slower repeated lazy reads) parse the `Data` through the
    /// generic ``parse(_:options:)-(some_ByteSource_&_Sendable,_)`` overload instead.
    public static func parse(_ data: Data, options: JSONParseOptions = .strict) throws(JSONError) -> JSONDocument {
        try parse(Array(data), options: options)
    }
}

extension JSONValue {
    /// Materialize a value tree from UTF-8 `Data`.
    public init(parsing data: Data, options: JSONParseOptions = .strict) throws(JSONError) {
        self.init(try ADJSON.parse(data, options: options).root)
    }

    /// Serialize to compact UTF-8 JSON `Data` (the Foundation-returning counterpart of the core
    /// `encodedBytes()`). Throws `EncodingError.invalidValue` on a non-finite number under the
    /// strict default; see `encodedBytes(options:)` for the byte-returning core API.
    public func encoded(options: JSONEncodingOptions = .rfc8259) throws -> Data {
        Data(try encodedBytes(options: options))
    }
}

extension JSONPatch {
    /// Parse an RFC 6902 patch document from UTF-8 `Data`.
    public init(_ data: Data) throws { try self.init(ADJSON.parse(data).root) }

    /// Apply this patch to a target encoded as UTF-8 `Data`, returning the patched document as `Data`.
    public func apply(toData data: Data) throws -> Data {
        try apply(to: JSONValue(parsing: data)).encoded()
    }
}

extension JSONMergePatch {
    /// Apply an RFC 7396 merge patch (`Data`) to a target (`Data`), returning the merged document.
    public static func apply(_ patchData: Data, toData targetData: Data) throws -> Data {
        try apply(JSONValue(parsing: patchData), to: JSONValue(parsing: targetData)).encoded()
    }
}
