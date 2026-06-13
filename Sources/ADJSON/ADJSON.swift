import Foundation

/// Namespace for the ADJSON library. Use `ADJSON.JSONDecoder` / `ADJSON.JSONEncoder`
/// / `ADJSON.JSONSerialization` where Foundation's same-named types are also in scope.
public enum ADJSON {
    /// Parse UTF-8 `Data` into an immutable, lazily-navigable document.
    public static func parse(_ data: Data, options: JSONParseOptions = .strict) throws -> JSONDocument {
        try parse([UInt8](data), options: options)
    }

    /// Parse a UTF-8 byte buffer into an immutable, lazily-navigable document.
    public static func parse(_ bytes: [UInt8], options: JSONParseOptions = .strict) throws -> JSONDocument {
        guard !bytes.isEmpty else { throw JSONError.unexpectedEndOfInput }
        guard bytes.count <= 0xFFFF_FFFF else { throw JSONError.documentTooLarge }
        let tape = try bytes.withUnsafeBufferPointer { bp -> [UInt64] in
            guard let base = bp.baseAddress else { throw JSONError.unexpectedEndOfInput }
            var builder = TapeBuilder(base, bp.count, options: options)
            return try builder.build()
        }
        ADJSONMetrics.record(bytes: bytes.count)
        return JSONDocument(bytes: bytes, tape: tape)
    }

    /// Parse a `String` into an immutable, lazily-navigable document.
    public static func parse(_ string: String, options: JSONParseOptions = .strict) throws -> JSONDocument {
        try parse(Array(string.utf8), options: options)
    }
}
