/// A borrowable, contiguous run of UTF-8 input bytes. Lets a ``JSONDocument`` retain an owner that
/// already holds its bytes contiguously — most importantly Foundation's `Data` — and read them
/// in place, so `parse` over such an owner needs **no** copy into a `[UInt8]`. The bytes are only
/// ever borrowed inside `withBytes`, exactly as the parsed document does for the lifetime invariant.
///
/// Conformers must expose a single, stable view of the same bytes on every call (value-semantic
/// owners like `Data` satisfy this for free). The tape stores byte *offsets*, so re-borrowing the
/// same immutable owner later yields identical bytes regardless of the pointer's address.
public protocol ByteSource {
    func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R
}

extension ADJSON {
    /// Parse a ``ByteSource`` (e.g. `Data`) into a document that **retains the source** and reads
    /// its bytes in place — no copy into a `[UInt8]`. The source must be `Sendable` so the resulting
    /// immutable ``JSONDocument`` stays `Sendable`. Value-semantic sources (CoW) make this safe: a
    /// later mutation of the caller's copy can't disturb the bytes this document borrows.
    public static func parse(
        _ source: some ByteSource & Sendable, options: JSONParseOptions = .strict
    ) throws(JSONError) -> JSONDocument {
        let count = source.withBytes { $0.count }
        guard count > 0 else { throw JSONError.unexpectedEndOfInput }
        guard UInt64(count) <= 0xFFFF_FFFF else { throw JSONError.documentTooLarge }
        // Same typed-throws funnel as `parse([UInt8])`: `withBytes` is untyped `rethrows`, so the
        // closure stays non-throwing and carries the `JSONError` out through `Result`.
        let tape = try source.withBytes { raw -> Result<ContiguousArray<UInt64>, JSONError> in
            guard let rawBase = raw.baseAddress else { return .failure(.unexpectedEndOfInput) }
            var builder = TapeBuilder(rawBase.assumingMemoryBound(to: UInt8.self), raw.count, options: options)
            return Result { () throws(JSONError) in try builder.build() }
        }.get()
        ADJSON.Metrics.record(bytes: count)
        return JSONDocument(
            backing: .source(source), tape: tape,
            keysAreUnique: options.duplicateKeys == .throwError, isJSON5: options.isJSON5)
    }
}
