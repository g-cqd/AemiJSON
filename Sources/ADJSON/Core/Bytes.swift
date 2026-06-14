// Safe access to a parsed document's contiguous storage without force-unwrapping
// `baseAddress`. A `JSONDocument` always owns non-empty `bytes`/`tape` (ADJSON.parse
// rejects empty input and every valid document has at least one tape slot), so the
// empty branch is unreachable and asserted rather than `!`-unwrapped.
extension JSONDocument {
    @inline(__always)
    func withBytePointer<R>(_ body: (UnsafePointer<UInt8>) -> R) -> R {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                preconditionFailure("JSONDocument.bytes is never empty")
            }
            return body(base)
        }
    }

    @inline(__always)
    func withBuffers<R>(_ body: (UnsafePointer<UInt8>, Int, UnsafePointer<UInt64>, Int) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer { byteBuffer in
            try tape.withUnsafeBufferPointer { tapeBuffer in
                guard let byteBase = byteBuffer.baseAddress, let tapeBase = tapeBuffer.baseAddress else {
                    preconditionFailure("JSONDocument storage is never empty")
                }
                return try body(byteBase, byteBuffer.count, tapeBase, tapeBuffer.count)
            }
        }
    }
}
