import ADJSONCore
public import Foundation

// Foundation interop: the `Data`-based conveniences that mirror Foundation's JSON API, layered on
// top of the Foundation-free `ADJSONCore` engine. Keeping these here is what lets the core stay
// dependency-free while `import ADJSON` consumers keep the familiar `Data`-returning surface.
//
// The byte-buffer / `String` entry points live in the core and are zero-extra-copy; a `Data` input
// is copied once into a `[UInt8]` here at the boundary (`Array(data)`). Parsing touches every input
// byte regardless, so the single copy is negligible against parse cost, and it keeps the core from
// naming `Data`.

extension ADJSON {
    /// Parse UTF-8 `Data` into an immutable, lazily-navigable document.
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
