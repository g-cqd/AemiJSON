import ADFCore

public enum JSONString {
    // Decode a JSON string body (between quotes) that contains escape sequences.
    // The no-escape fast path is handled by the caller via `String(decoding:)`.
    public static func unescape(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> String {
        // Caller owns `p` for `p[offset ..< offset + length]` for this call; reads stay in that range
        // and `p` never escapes. Offsets/lengths come from the tape and are non-negative.
        assert(offset >= 0 && length >= 0, "unescape requires a non-negative byte range")
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var j = offset
        let end = offset + length
        while j < end {
            let c = unsafe p[j]
            if c != 0x5C {
                out.append(c)
                j += 1
                continue
            }
            j += 1
            guard j < end else { break }
            let e = unsafe p[j]
            j += 1
            switch e {
                case 0x22: out.append(0x22)
                case 0x5C: out.append(0x5C)
                case 0x2F: out.append(0x2F)
                case 0x6E: out.append(0x0A)
                case 0x74: out.append(0x09)
                case 0x72: out.append(0x0D)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x75:
                    let hi = unsafe readHex4(p, j, end)
                    j += 4
                    var scalar = UInt32(hi)
                    if hi >= 0xD800 && hi <= 0xDBFF, j + 1 < end, unsafe p[j] == 0x5C, unsafe p[j + 1] == 0x75 {
                        let lo = unsafe readHex4(p, j + 2, end)
                        if lo >= 0xDC00 && lo <= 0xDFFF {
                            scalar = 0x10000 + ((UInt32(hi) - 0xD800) << 10) + (UInt32(lo) - 0xDC00)
                            j += 6
                        }
                    }
                    if let us = Unicode.Scalar(scalar) {
                        Unicode.UTF8.encode(us) { out.append($0) }
                    } else {
                        out.append(contentsOf: [0xEF, 0xBF, 0xBD])  // U+FFFD
                    }
                default:
                    out.append(e)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // Decode a JSON5 string body. Adds to the JSON escapes: `\'`, `\v`, `\0`, `\xHH`, line
    // continuations (`\` + LF/CR/CRLF/U+2028/U+2029 → elided), and identity escapes (`\X` → `X`).
    // The scanner has already validated these, so this only re-materializes them.
    public static func unescapeJSON5(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> String {
        // Same contract as `unescape`: caller owns `p[offset ..< offset + length]`, `p` does not escape.
        assert(offset >= 0 && length >= 0, "unescapeJSON5 requires a non-negative byte range")
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var j = offset
        let end = offset + length
        unescape: while j < end {
            let c = unsafe p[j]
            if c != 0x5C {
                out.append(c)
                j += 1
                continue
            }
            j += 1
            guard j < end else { break }
            let e = unsafe p[j]
            j += 1
            switch e {
                case 0x22: out.append(0x22)  // \"
                case 0x27: out.append(0x27)  // \'
                case 0x5C: out.append(0x5C)  // \\
                case 0x2F: out.append(0x2F)  // \/
                case 0x6E: out.append(0x0A)  // \n
                case 0x74: out.append(0x09)  // \t
                case 0x72: out.append(0x0D)  // \r
                case 0x62: out.append(0x08)  // \b
                case 0x66: out.append(0x0C)  // \f
                case 0x76: out.append(0x0B)  // \v
                case 0x30: out.append(0x00)  // \0 (scanner ensured no trailing digit)
                case 0x78:  // \xHH → U+00HH (value <= 0xFF: the non-failable UInt8 scalar init, no force-unwrap)
                    // The scanner guarantees two hex digits follow, but don't make the in-bounds read
                    // depend on that invariant alone: bail if the buffer is somehow short.
                    guard j + 1 < end else { break unescape }
                    let value = unsafe UInt32(Hex.value(p[j]) ?? 0) << 4 | UInt32(Hex.value(p[j + 1]) ?? 0)
                    j += 2
                    Unicode.UTF8.encode(Unicode.Scalar(UInt8(truncatingIfNeeded: value))) { out.append($0) }
                case 0x75:  // \uHHHH (+ surrogate pair)
                    let hi = unsafe readHex4(p, j, end)
                    j += 4
                    var scalar = UInt32(hi)
                    if hi >= 0xD800 && hi <= 0xDBFF, j + 1 < end, unsafe p[j] == 0x5C, unsafe p[j + 1] == 0x75 {
                        let lo = unsafe readHex4(p, j + 2, end)
                        if lo >= 0xDC00 && lo <= 0xDFFF {
                            scalar = 0x10000 + ((UInt32(hi) - 0xD800) << 10) + (UInt32(lo) - 0xDC00)
                            j += 6
                        }
                    }
                    if let us = Unicode.Scalar(scalar) {
                        Unicode.UTF8.encode(us) { out.append($0) }
                    } else {
                        out.append(contentsOf: [0xEF, 0xBF, 0xBD])  // U+FFFD
                    }
                case 0x0A: break  // \ + LF → line continuation (elided)
                case 0x0D: if j < end, unsafe p[j] == 0x0A { j += 1 }  // \ + CR / CRLF → elided
                default:
                    if e >= 0x80 {  // identity-escaped multi-byte scalar, or a U+2028/U+2029 continuation
                        let len = e >= 0xF0 ? 4 : (e >= 0xE0 ? 3 : 2)
                        if len == 3, e == 0xE2, j + 1 < end, unsafe p[j] == 0x80,
                            unsafe p[j + 1] == 0xA8 || p[j + 1] == 0xA9
                        {
                            j += 2  // elide the U+2028/U+2029 line continuation (lead already consumed)
                        } else {
                            out.append(e)
                            for _ in 1 ..< len where j < end {
                                out.append(unsafe p[j])
                                j += 1
                            }
                        }
                    } else {
                        out.append(e)  // identity escape \X → X
                    }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // Compare the strict-unescaped form of `p[offset..<offset+length]` to `target` byte-for-byte,
    // decoding escapes on the fly so no intermediate `String`/`[UInt8]` is allocated. Behaviour is
    // identical to `unescape(p, offset, length) == String(decoding: target)`, just allocation-free —
    // used by the object-key compare path where most keys are unescaped but some are not.
    public static func unescapedEquals(
        _ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int, _ target: UnsafePointer<UInt8>, _ targetLength: Int
    ) -> Bool {
        // Caller owns `p[offset ..< offset + length]` and `target[0 ..< targetLength]` for this call;
        // neither pointer escapes. All four indices are non-negative (tape- / String-UTF8-derived).
        assert(offset >= 0 && length >= 0 && targetLength >= 0, "unescapedEquals requires non-negative ranges")
        var t = 0
        // Match one decoded byte against the target; false on overrun or mismatch.
        func emit(_ b: UInt8) -> Bool {
            if unsafe t >= targetLength || target[t] != b { return false }
            t += 1
            return true
        }
        var j = offset
        let end = offset + length
        while j < end {
            let c = unsafe p[j]
            if c != 0x5C {
                if !emit(c) { return false }
                j += 1
                continue
            }
            j += 1
            guard j < end else { break }
            let e = unsafe p[j]
            j += 1
            switch e {
                case 0x22: if !emit(0x22) { return false }
                case 0x5C: if !emit(0x5C) { return false }
                case 0x2F: if !emit(0x2F) { return false }
                case 0x6E: if !emit(0x0A) { return false }
                case 0x74: if !emit(0x09) { return false }
                case 0x72: if !emit(0x0D) { return false }
                case 0x62: if !emit(0x08) { return false }
                case 0x66: if !emit(0x0C) { return false }
                case 0x75:
                    if unsafe !decodeUnicodeEscape(p, &j, end, emit) { return false }
                default: if !emit(e) { return false }
            }
        }
        return t == targetLength
    }

    /// Decodes a `\uXXXX` escape (with optional surrogate-pair continuation) at `p[j]`,
    /// advancing `j`, and feeds the scalar's UTF-8 bytes to `emit` — U+FFFD for an
    /// unpaired / out-of-range surrogate, matching `unescape`. Returns false on a mismatch.
    private static func decodeUnicodeEscape(
        _ p: UnsafePointer<UInt8>, _ j: inout Int, _ end: Int, _ emit: (UInt8) -> Bool
    ) -> Bool {
        let hi = unsafe readHex4(p, j, end)
        j += 4
        var scalar = UInt32(hi)
        if hi >= 0xD800 && hi <= 0xDBFF, j + 1 < end, unsafe p[j] == 0x5C, unsafe p[j + 1] == 0x75 {
            let lo = unsafe readHex4(p, j + 2, end)
            if lo >= 0xDC00 && lo <= 0xDFFF {
                scalar = 0x10000 + ((UInt32(hi) - 0xD800) << 10) + (UInt32(lo) - 0xDC00)
                j += 6
            }
        }
        guard Unicode.Scalar(scalar) != nil else { return emit(0xEF) && emit(0xBF) && emit(0xBD) }
        if scalar < 0x80 {
            return emit(UInt8(scalar))
        } else if scalar < 0x800 {
            return emit(UInt8(0xC0 | (scalar >> 6))) && emit(UInt8(0x80 | (scalar & 0x3F)))
        } else if scalar < 0x10000 {
            return emit(UInt8(0xE0 | (scalar >> 12))) && emit(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
                && emit(UInt8(0x80 | (scalar & 0x3F)))
        }
        return emit(UInt8(0xF0 | (scalar >> 18))) && emit(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
            && emit(UInt8(0x80 | ((scalar >> 6) & 0x3F))) && emit(UInt8(0x80 | (scalar & 0x3F)))
    }

    @inline(__always)
    private static func readHex4(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> UInt16 {
        var v: UInt16 = 0
        var k = start
        let stop = min(start + 4, end)
        while k < stop {
            v = unsafe (v << 4) | UInt16(Hex.value(p[k]) ?? 0)
            k += 1
        }
        return v
    }
}
