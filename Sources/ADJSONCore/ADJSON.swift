/// Namespace for the ADJSON library. Use `ADJSON.JSONDecoder` / `ADJSON.JSONEncoder`
/// / `ADJSON.JSONSerialization` where Foundation's same-named types are also in scope.
public enum ADJSON {
    /// Parse a UTF-8 byte buffer into an immutable, lazily-navigable document.
    public static func parse(_ bytes: [UInt8], options: JSONParseOptions = .strict) throws(JSONError) -> JSONDocument {
        if options.assumesTopLevelDictionary { return try parseAssumingTopLevelDictionary(bytes, options: options) }
        guard !bytes.isEmpty else { throw JSONError.unexpectedEndOfInput }
        guard UInt64(bytes.count) <= 0xFFFF_FFFF else { throw JSONError.documentTooLarge }
        // `withUnsafeBufferPointer` is untyped `rethrows` (it erases the closure's error to
        // `any Error`), so the closure stays non-throwing and funnels the typed `JSONError`
        // out through `Result`, whose `.get()` is itself `throws(JSONError)`.
        let tape = try bytes.withUnsafeBufferPointer { bp -> Result<ContiguousArray<UInt64>, JSONError> in
            guard let base = bp.baseAddress else { return .failure(.unexpectedEndOfInput) }
            var builder = TapeBuilder(base, bp.count, options: options)
            return Result { () throws(JSONError) in try builder.build() }
        }.get()
        ADJSON.Metrics.record(bytes: bytes.count)
        return JSONDocument(
            backing: .bytes(bytes), tape: tape,
            keysAreUnique: options.duplicateKeys == .throwError, isJSON5: options.isJSON5)
    }

    /// Parse a `String` into an immutable, lazily-navigable document.
    public static func parse(_ string: String, options: JSONParseOptions = .strict) throws(JSONError) -> JSONDocument {
        try parse(Array(string.utf8), options: options)
    }

    // `assumesTopLevelDictionary`: wrap the input in `{ … }` unless its first significant byte is
    // already `{`, then parse with the flag cleared (one-shot). Leaving an already-braced input
    // untouched is what makes a single unmatched brace still a parse error.
    static func parseAssumingTopLevelDictionary(
        _ bytes: [UInt8], options: JSONParseOptions
    ) throws(JSONError) -> JSONDocument {
        var plain = options
        plain.assumesTopLevelDictionary = false
        let firstSignificant = bytes.first { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
        if firstSignificant == 0x7B { return try parse(bytes, options: plain) }  // already an object
        var wrapped: [UInt8] = []
        wrapped.reserveCapacity(bytes.count + 2)
        wrapped.append(0x7B)  // '{'
        wrapped.append(contentsOf: bytes)
        wrapped.append(0x7D)  // '}'
        return try parse(wrapped, options: plain)
    }
}
