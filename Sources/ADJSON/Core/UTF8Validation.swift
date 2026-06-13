// RFC 3629 UTF-8 well-formedness. Rejects invalid lead/continuation bytes, overlong
// encodings, surrogate code points (U+D800–U+DFFF), and values above U+10FFFF.

/// Validate the multi-byte UTF-8 sequence starting at `j` (where `p[j] >= 0x80`),
/// returning its length in bytes. Throws `JSONError.invalidUTF8` if malformed.
@inline(__always)
func utf8SequenceLength(_ p: UnsafePointer<UInt8>, _ j: Int, _ n: Int) throws -> Int {
    let b = p[j]
    let length: Int
    let lowerBound: UInt32
    var scalar: UInt32
    if b & 0xE0 == 0xC0 {
        length = 2
        lowerBound = 0x80
        scalar = UInt32(b & 0x1F)
    } else if b & 0xF0 == 0xE0 {
        length = 3
        lowerBound = 0x800
        scalar = UInt32(b & 0x0F)
    } else if b & 0xF8 == 0xF0 {
        length = 4
        lowerBound = 0x1_0000
        scalar = UInt32(b & 0x07)
    } else {
        throw JSONError.invalidUTF8(at: j)  // continuation byte or invalid lead (0xF8+)
    }
    guard j + length <= n else { throw JSONError.invalidUTF8(at: j) }
    for k in 1..<length {
        let cont = p[j + k]
        guard cont & 0xC0 == 0x80 else { throw JSONError.invalidUTF8(at: j) }
        scalar = (scalar << 6) | UInt32(cont & 0x3F)
    }
    let upperBound: UInt32 = length == 2 ? 0x7FF : (length == 3 ? 0xFFFF : 0x10_FFFF)
    guard scalar >= lowerBound, scalar <= upperBound else { throw JSONError.invalidUTF8(at: j) }
    guard !(scalar >= 0xD800 && scalar <= 0xDFFF) else { throw JSONError.invalidUTF8(at: j) }
    return length
}

/// Whole-buffer well-formedness check (used where a single pass is acceptable).
func isValidUTF8(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
    var i = 0
    while i < n {
        if p[i] < 0x80 {
            i += 1
        } else if let length = try? utf8SequenceLength(p, i, n) {
            i += length
        } else {
            return false
        }
    }
    return true
}
