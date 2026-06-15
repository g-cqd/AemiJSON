public enum JSONString {
    // Decode a JSON string body (between quotes) that contains escape sequences.
    // The no-escape fast path is handled by the caller via `String(decoding:)`.
    public static func unescape(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> String {
        var out = [UInt8]()
        out.reserveCapacity(length)
        var j = offset
        let end = offset + length
        while j < end {
            let c = p[j]
            if c != 0x5C {
                out.append(c)
                j += 1
                continue
            }
            j += 1
            guard j < end else { break }
            let e = p[j]
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
                let hi = readHex4(p, j, end)
                j += 4
                var scalar = UInt32(hi)
                if hi >= 0xD800 && hi <= 0xDBFF, j + 1 < end, p[j] == 0x5C, p[j + 1] == 0x75 {
                    let lo = readHex4(p, j + 2, end)
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
        var out = [UInt8]()
        out.reserveCapacity(length)
        var j = offset
        let end = offset + length
        while j < end {
            let c = p[j]
            if c != 0x5C {
                out.append(c)
                j += 1
                continue
            }
            j += 1
            guard j < end else { break }
            let e = p[j]
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
            case 0x78:  // \xHH → U+00HH
                let value = UInt32(hexValue(p[j])) << 4 | UInt32(hexValue(p[j + 1]))
                j += 2
                Unicode.UTF8.encode(Unicode.Scalar(value)!) { out.append($0) }
            case 0x75:  // \uHHHH (+ surrogate pair)
                let hi = readHex4(p, j, end)
                j += 4
                var scalar = UInt32(hi)
                if hi >= 0xD800 && hi <= 0xDBFF, j + 1 < end, p[j] == 0x5C, p[j + 1] == 0x75 {
                    let lo = readHex4(p, j + 2, end)
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
            case 0x0D: if j < end, p[j] == 0x0A { j += 1 }  // \ + CR / CRLF → elided
            default:
                if e >= 0x80 {  // identity-escaped multi-byte scalar, or a U+2028/U+2029 continuation
                    let len = e >= 0xF0 ? 4 : (e >= 0xE0 ? 3 : 2)
                    if len == 3, e == 0xE2, j + 1 < end, p[j] == 0x80, p[j + 1] == 0xA8 || p[j + 1] == 0xA9 {
                        j += 2  // elide the U+2028/U+2029 line continuation (lead already consumed)
                    } else {
                        out.append(e)
                        for _ in 1..<len where j < end {
                            out.append(p[j])
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

    @inline(__always)
    private static func readHex4(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> UInt16 {
        var v: UInt16 = 0
        var k = start
        let stop = min(start + 4, end)
        while k < stop {
            v = (v << 4) | UInt16(hexValue(p[k]))
            k += 1
        }
        return v
    }

    @inline(__always)
    private static func hexValue(_ b: UInt8) -> UInt8 {
        if b >= 0x30 && b <= 0x39 { return b - 0x30 }
        if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
        if b >= 0x41 && b <= 0x46 { return b - 0x41 + 10 }
        return 0
    }
}
