import Foundation

// Safe access to a parsed document's contiguous UTF-8 storage without force-unwrapping
// `baseAddress`. A `JSONDocument` always owns non-empty input (`ADJSON.parse` rejects empty
// input and every valid document has at least one tape slot), so the empty branch is
// unreachable and asserted rather than `!`-unwrapped.
extension JSONDocument {
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
        case .data(let d):
            return try d.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else {
                    preconditionFailure("JSONDocument input is never empty")
                }
                return try body(base.assumingMemoryBound(to: UInt8.self))
            }
        }
    }

    @inline(__always)
    func withBuffers<R>(_ body: (UnsafePointer<UInt8>, Int, UnsafePointer<UInt64>, Int) throws -> R) rethrows -> R {
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
