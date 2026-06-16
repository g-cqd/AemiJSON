/// A borrowable, contiguous run of UTF-8 input bytes. Lets a ``JSONDocument`` retain an owner that
/// already holds its bytes contiguously — most importantly Foundation's `Data` — and read them
/// in place, so `parse` over such an owner needs **no** copy into a `[UInt8]`. The bytes are only
/// ever borrowed inside `withBytes`, exactly as the parsed document does for the lifetime invariant.
///
/// Conformers must expose a single, stable view of the same bytes on every call (value-semantic
/// owners like `Data` satisfy this for free). The tape stores byte *offsets*, so re-borrowing the
/// same immutable owner later yields identical bytes regardless of the pointer's address.
///
/// CONCURRENCY: `withBytes` must support **concurrent** invocation — `ADJSON.decodeArrayConcurrently`
/// borrows the source from many tasks at once, each binding its own pointer over the same immutable
/// bytes. A read-only borrow of immutable storage is inherently safe, which value-semantic
/// (copy-on-write) owners like `Data` provide for free; a custom conformer that mutates shared
/// state inside `withBytes` (or hands out a pointer into a buffer it concurrently mutates) breaks
/// this and must not be used with the concurrent decoder.
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

    /// Parse a **caller-owned, borrowed** raw buffer with no copy: the resulting ``JSONDocument``
    /// reads the bytes in place (its tape stores byte offsets into `buffer`), so this is the
    /// lowest-overhead entry for an FFI payload or any buffer already held contiguously.
    ///
    /// - Important: `buffer` is *borrowed, not retained*. It must stay alive and unmodified for the
    ///   entire lifetime of the returned document — every lazy ``JSON`` read, and any value derived
    ///   from one, dereferences it. Using the document after `buffer` is deallocated or mutated is
    ///   undefined behavior. This is the same lifetime contract a zero-copy FFI tape carries: parse,
    ///   read, and drop the document within the borrow. When the buffer cannot outlive the document,
    ///   copy into `[UInt8]` and use ``parse(_:options:)-(_,_)`` instead. The `RawSpan` overload (a
    ///   lifetime-checked form) is the safer long-term entry where available.
    public static func parse(
        _ buffer: UnsafeRawBufferPointer, options: JSONParseOptions = .strict
    ) throws(JSONError) -> JSONDocument {
        try parse(BorrowedRawBytes(buffer), options: options)
    }
}

/// A ``ByteSource`` over a borrowed raw buffer used by ``ADJSON/parse(_:options:)-(UnsafeRawBufferPointer,_)``.
/// It copies nothing; it forwards the caller's buffer on every `withBytes`.
///
/// `@unchecked Sendable` is sound only under the borrowed-parse lifetime contract: the bytes are
/// immutable for the borrow's duration, so the read-only pointer can be shared across the concurrent
/// decoder's tasks (each binds its own pointer over the same immutable bytes). A caller that mutates
/// the buffer concurrently, or lets it outlive its memory, violates the contract and the safety
/// guarantee with it.
struct BorrowedRawBytes: ByteSource, @unchecked Sendable {
    let buffer: UnsafeRawBufferPointer
    init(_ buffer: UnsafeRawBufferPointer) { self.buffer = buffer }
    func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try body(buffer) }
}
