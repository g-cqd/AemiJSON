public import Foundation

/// Namespace for the ADJSON library. Use `ADJSON.JSONDecoder` / `ADJSON.JSONEncoder`
/// / `ADJSON.JSONSerialization` where Foundation's same-named types are also in scope.
public enum ADJSON {
    /// Parse UTF-8 `Data` into an immutable, lazily-navigable document.
    public static func parse(_ data: Data, options: JSONParseOptions = .strict) throws(JSONError) -> JSONDocument {
        guard !data.isEmpty else { throw JSONError.unexpectedEndOfInput }
        guard data.count <= 0xFFFF_FFFF else { throw JSONError.documentTooLarge }
        // Parse over the `Data`'s own storage and retain it — no intermediate `[UInt8]` copy of the
        // input is made on this (server-hot) path. `withUnsafeBytes` is untyped `rethrows`, so the
        // typed `JSONError` funnels out through `Result.get()` as in `parse(_:[UInt8])`.
        let tape = try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Result<[UInt64], JSONError> in
            guard let base = raw.baseAddress else { return .failure(.unexpectedEndOfInput) }
            var builder = TapeBuilder(base.assumingMemoryBound(to: UInt8.self), raw.count, options: options)
            return Result { () throws(JSONError) in try builder.build() }
        }.get()
        ADJSONMetrics.record(bytes: data.count)
        return JSONDocument(backing: .data(data), tape: tape)
    }

    /// Parse a UTF-8 byte buffer into an immutable, lazily-navigable document.
    public static func parse(_ bytes: [UInt8], options: JSONParseOptions = .strict) throws(JSONError) -> JSONDocument {
        guard !bytes.isEmpty else { throw JSONError.unexpectedEndOfInput }
        guard bytes.count <= 0xFFFF_FFFF else { throw JSONError.documentTooLarge }
        // `withUnsafeBufferPointer` is untyped `rethrows` (it erases the closure's error to
        // `any Error`), so the closure stays non-throwing and funnels the typed `JSONError`
        // out through `Result`, whose `.get()` is itself `throws(JSONError)`.
        let tape = try bytes.withUnsafeBufferPointer { bp -> Result<[UInt64], JSONError> in
            guard let base = bp.baseAddress else { return .failure(.unexpectedEndOfInput) }
            var builder = TapeBuilder(base, bp.count, options: options)
            return Result { () throws(JSONError) in try builder.build() }
        }.get()
        ADJSONMetrics.record(bytes: bytes.count)
        return JSONDocument(backing: .bytes(bytes), tape: tape)
    }

    /// Parse a `String` into an immutable, lazily-navigable document.
    public static func parse(_ string: String, options: JSONParseOptions = .strict) throws(JSONError) -> JSONDocument {
        try parse(Array(string.utf8), options: options)
    }
}
