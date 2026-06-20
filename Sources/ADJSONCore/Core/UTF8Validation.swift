import ADFCore

// RFC 3629 UTF-8 well-formedness, delegating to ``ADFCore/UTF8Validation`` (the single
// implementation). This thin wrapper keeps the scanner/tokenizer hot path's throwing API:
// a malformed sequence maps to `JSONError.invalidUTF8(at:)`.
enum JSONUTF8 {
    /// The expected byte length (2–4) of a multi-byte sequence from its lead byte, or `nil` for an
    /// invalid lead. Lets a resumable scanner decide how many bytes it must wait for.
    @inline(__always)
    static func leadLength(_ b: UInt8) -> Int? { UTF8Validation.leadLength(b) }

    /// Validate the multi-byte UTF-8 sequence starting at `j` (where `p[j] >= 0x80`), returning its
    /// length in bytes. Throws `JSONError.invalidUTF8` if malformed.
    @inline(__always)
    static func sequenceLength(_ p: UnsafePointer<UInt8>, _ j: Int, _ n: Int) throws(JSONError) -> Int {
        guard let length = unsafe UTF8Validation.sequenceLength(p, j, n) else { throw JSONError.invalidUTF8(at: j) }
        return length
    }
}
