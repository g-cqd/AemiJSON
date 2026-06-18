// Safe access to a parsed document's contiguous UTF-8 storage without force-unwrapping
// `baseAddress`. A `JSONDocument` always owns non-empty input (`ADJSON.parse` rejects empty
// input and every valid document has at least one tape slot), so the empty branch is
// unreachable and asserted rather than `!`-unwrapped.
extension JSONDocument {
    /// Owner/lifetime/bounds: the pointer passed to `body` addresses this document's contiguous UTF-8
    /// storage, valid for exactly `backing.count` bytes. `body` is non-escaping and the pointer must
    /// not outlive it (it is borrowed from the backing array / `ByteSource` for the call's duration
    /// only). The document owns the storage and is immutable, so concurrent readers may each take their
    /// own borrow.
    @inline(__always)
    func withBytePointer<R>(_ body: (UnsafePointer<UInt8>) throws -> R) rethrows -> R {
        switch backing {
            case .bytes(let b):
                return try b.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else {
                        preconditionFailure("JSONDocument input is never empty")
                    }
                    return try body(base)
                }
            case .source(let source):
                return try source.withBytes { raw in
                    guard let base = raw.baseAddress else {
                        preconditionFailure("JSONDocument input is never empty")
                    }
                    return try body(base.assumingMemoryBound(to: UInt8.self))
                }
        }
    }

    /// Owner/lifetime/bounds: `body` receives the byte base (valid for `backing.count` bytes) and the
    /// tape base (valid for `tape.count` slots). Both are borrowed for the call only — `body` is
    /// non-escaping and neither pointer may outlive it. Hoist this once per task and read through the
    /// raw pointers in the inner loop: re-deriving the pointers per element re-borrows the shared
    /// storage and, across threads, contends on its reference count.
    @inline(__always)
    package func withBuffers<R>(
        _ body: (UnsafePointer<UInt8>, Int, UnsafePointer<UInt64>, Int) throws -> R
    ) rethrows -> R {
        try withBytePointer { byteBase in
            try tape.withUnsafeBufferPointer { tapeBuffer in
                guard let tapeBase = tapeBuffer.baseAddress else {
                    preconditionFailure("JSONDocument tape is never empty")
                }
                return try body(byteBase, backing.count, tapeBase, tapeBuffer.count)
            }
        }
    }
}
