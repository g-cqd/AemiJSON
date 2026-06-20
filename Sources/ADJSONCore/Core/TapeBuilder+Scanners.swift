import ADFCore

// Scalar token scanners for `TapeBuilder`: the strict / lenient / JSON5 string and number scanners
// plus the shared hex, digit, and literal primitives. Split from Scanner.swift to keep the
// structural scan loop (the `TapeBuilder` type body) within the size/complexity gate; the accepted
// grammar is unchanged (NumberGrammarParityTests and the JSONTestSuite corpus bind both halves).
extension TapeBuilder {
    // Records the string's content range + hasEscape flag; validates escapes and
    // UTF-8 in strict mode. Does not decode.
    mutating func scanString() throws(JSONError) {
        if json5 {
            try scanStringJSON5()
            return
        }
        let start = i + 1
        var j = start
        var esc: UInt64 = 0
        while j < n {
            // SWAR fast-forward over a run of plain content bytes — printable ASCII that is neither a
            // quote, a backslash, a control char, nor a non-ASCII lead. Eight bytes are tested per
            // step; on a clean word `j` jumps by 8, otherwise to the first byte the scalar tail must
            // inspect. Only whole words inside the buffer are loaded (`j + 8 <= n`).
            while j + 8 <= n {
                let word = UInt64(littleEndian: unsafe UnsafeRawPointer(p + j).loadUnaligned(as: UInt64.self))
                let mask = Self.stringStopMask(word)
                if mask == 0 {
                    j += 8
                    continue
                }
                j += mask.trailingZeroBitCount >> 3  // first stop byte (its 0x80 bit, /8)
                break
            }
            guard j < n else { break }
            let c = unsafe p[j]
            if c == 0x22 { break }
            if c == 0x5C {
                esc = 1
                if strict {
                    try validateEscape(&j)
                } else {
                    j += 2
                }
                continue
            }
            if c < 0x20 { throw JSONError.invalidString(at: j) }
            if strict && c >= 0x80 {
                // Validate the whole run of non-ASCII (multi-byte) sequences in a tight loop, rather
                // than bouncing back to the ASCII SWAR scan (which stops on the very first non-ASCII
                // byte) after each character. Stop bytes — quote / backslash / controls — are all
                // < 0x80, so `p[j] >= 0x80` means another multi-byte lead; the run ends at the first
                // ASCII byte. Each sequence is still fully validated (overlong / surrogate / bounds).
                repeat {
                    j += try unsafe JSONUTF8.sequenceLength(p, j, n)
                } while unsafe j < n && p[j] >= 0x80
                continue
            }
            j += 1
        }
        guard j < n else { throw JSONError.unexpectedEndOfInput }
        let length = j - start
        guard length <= Slot.maxLength else { throw JSONError.documentTooLarge }
        slots.append(Slot.scalar(JSONKind.string.rawValue, offset: start, length: length, flags: esc))
        i = j + 1
    }

    // SWAR: returns a word whose every byte holds `0x80` exactly where the corresponding input byte
    // must stop the fast scan — a control char (`< 0x20`), a non-ASCII lead (`>= 0x80`), a quote
    // (`"`), or a backslash (`\`). Zero means all eight bytes are plain string content. The set bits
    // are only ever the per-byte `0x80`, so `trailingZeroBitCount >> 3` (little-endian) locates the
    // first stop byte. Uses the classic "bytes < n" / "bytes == c" bit hacks (Bit Twiddling Hacks).
    @inline(__always) static func stringStopMask(_ v: UInt64) -> UInt64 {
        // Parse stops on a control, a non-ASCII lead, a quote, or a backslash. (Encode shares the
        // control/quote/backslash terms but omits non-ASCII — UTF-8 is copied verbatim there.)
        SWAR.lessThan(v, 0x20) | SWAR.nonASCII(v) | SWAR.equals(v, 0x22) | SWAR.equals(v, 0x5C)
    }

    // `p[j]` is a backslash; validates the escape and advances `j` past it.
    mutating func validateEscape(_ j: inout Int) throws(JSONError) {
        guard j + 1 < n else { throw JSONError.invalidString(at: j) }
        switch unsafe p[j + 1] {
            case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                j += 2
            case 0x75:  // \uXXXX
                let high = try hex4(j + 2)
                if high >= 0xD800 && high <= 0xDBFF {
                    guard j + 7 < n, unsafe p[j + 6] == 0x5C, unsafe p[j + 7] == 0x75 else {
                        throw JSONError.invalidString(at: j)
                    }
                    let low = try hex4(j + 8)
                    guard low >= 0xDC00 && low <= 0xDFFF else { throw JSONError.invalidString(at: j) }
                    j += 12
                } else if high >= 0xDC00 && high <= 0xDFFF {
                    throw JSONError.invalidString(at: j)  // lone low surrogate
                } else {
                    j += 6
                }
            default:
                throw JSONError.invalidString(at: j)  // invalid escape character
        }
    }

    // The 4-hex-digit decode is shared with the SAX scanner (`JSONString.hex4`); only the error shape
    // differs (the tape throws a positioned `JSONError`, the lexeme scanner returns nil).
    func hex4(_ at: Int) throws(JSONError) -> UInt16 {
        guard at + 4 <= n, let value = unsafe JSONString.hex4(p, at) else { throw JSONError.invalidString(at: at) }
        return value
    }

    // The tape's number scan: one pass that validates the lexeme AND classifies int-vs-double (the
    // `isInt` flag), tuned for throughput. It is a separate implementation of the same grammar the
    // resumable SAX scanner (`JSONNumber.scanLexeme`, Core/Tokenizer.swift) enforces;
    // `NumberGrammarParityTests` binds the two to the same accepted language.
    mutating func scanNumber() throws(JSONError) {
        let start = i
        var isInt: UInt64 = 1
        if json5 {
            try scanNumberJSON5(&isInt, start: start)
        } else if strict {
            try scanNumberStrict(&isInt, start: start)
        } else {
            // Lenient: relaxes the strict grammar (leading zeros, leading '+', trailing '.')
            // but still emits only well-formed number tokens, so a malformed run like `1.2.3`
            // or `1e` is rejected here rather than silently decoding to NaN/nil later.
            if unsafe i < n && (p[i] == 0x2D || p[i] == 0x2B) { i += 1 }
            let intStart = i
            while unsafe i < n && isDigit(p[i]) { i += 1 }
            var sawDigits = i > intStart
            if unsafe i < n && p[i] == 0x2E {
                isInt = 0
                i += 1
                let fracStart = i
                while unsafe i < n && isDigit(p[i]) { i += 1 }
                sawDigits = sawDigits || i > fracStart
            }
            guard sawDigits else { throw JSONError.invalidNumber(at: start) }
            if unsafe i < n && (p[i] == 0x65 || p[i] == 0x45) {
                isInt = 0
                i += 1
                if unsafe i < n && (p[i] == 0x2B || p[i] == 0x2D) { i += 1 }
                let expStart = i
                while unsafe i < n && isDigit(p[i]) { i += 1 }
                guard i > expStart else { throw JSONError.invalidNumber(at: start) }
            }
        }
        let length = i - start
        guard length > 0, length <= Slot.maxLength else { throw JSONError.invalidNumber(at: start) }
        if enforceIEEE754Numbers { try enforceIJSONNumberRange(start: start, length: length, isInt: isInt) }
        slots.append(Slot.scalar(JSONKind.number.rawValue, offset: start, length: length, flags: isInt))
    }

    // RFC 7493 I-JSON §2.2: an integer literal must lie within ±(2^53−1) to round-trip exactly
    // through a binary64 double, and no number may overflow to ±∞. Only reached under the `.iJSON`
    // profile, so the strict/lenient hot path pays nothing.
    func enforceIJSONNumberRange(start: Int, length: Int, isInt: UInt64) throws(JSONError) {
        if isInt == 1 {
            guard let value = unsafe JSONNumber.parseInteger(p, start, length, Int64.self),
                value >= -9_007_199_254_740_991, value <= 9_007_199_254_740_991
            else { throw JSONError.invalidNumber(at: start) }
        } else if unsafe !JSONNumber.parseDouble(p, start, length).isFinite {
            throw JSONError.invalidNumber(at: start)
        }
    }

    // RFC 8259: [ '-' ] ( '0' | [1-9][0-9]* ) [ '.' [0-9]+ ] [ (e|E) [+|-] [0-9]+ ]
    mutating func scanNumberStrict(_ isInt: inout UInt64, start: Int) throws(JSONError) {
        if unsafe i < n && p[i] == 0x2D { i += 1 }
        guard i < n else { throw JSONError.invalidNumber(at: start) }
        if unsafe p[i] == 0x30 {
            i += 1
            if unsafe i < n && isDigit(p[i]) { throw JSONError.invalidNumber(at: start) }  // no leading zero
        } else if unsafe p[i] >= 0x31 && p[i] <= 0x39 {
            i += 1
            while unsafe i < n && isDigit(p[i]) { i += 1 }
        } else {
            throw JSONError.invalidNumber(at: start)
        }
        if unsafe i < n && p[i] == 0x2E {
            isInt = 0
            i += 1
            guard unsafe i < n && isDigit(p[i]) else { throw JSONError.invalidNumber(at: start) }
            while unsafe i < n && isDigit(p[i]) { i += 1 }
        }
        if unsafe i < n && (p[i] == 0x65 || p[i] == 0x45) {
            isInt = 0
            i += 1
            if unsafe i < n && (p[i] == 0x2B || p[i] == 0x2D) { i += 1 }
            guard unsafe i < n && isDigit(p[i]) else { throw JSONError.invalidNumber(at: start) }
            while unsafe i < n && isDigit(p[i]) { i += 1 }
        }
    }

    @inline(__always) func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    mutating func scanLiteral() throws(JSONError) {
        let start = i
        switch unsafe p[i] {
            case 0x74:
                try expectLiteral("true")
                slots.append(Slot.scalar(JSONKind.boolTrue.rawValue, offset: start, length: 4, flags: 0))
            case 0x66:
                try expectLiteral("false")
                slots.append(Slot.scalar(JSONKind.boolFalse.rawValue, offset: start, length: 5, flags: 0))
            default:
                try expectLiteral("null")
                slots.append(Slot.scalar(JSONKind.null.rawValue, offset: start, length: 4, flags: 0))
        }
    }

    @inline(__always) mutating func expectLiteral(_ lit: StaticString) throws(JSONError) {
        let len = lit.utf8CodeUnitCount
        guard i + len <= n, unsafe JSONKey.bytesEqual(p + i, lit.utf8Start, len) else {
            throw JSONError.unexpectedCharacter(i < n ? unsafe p[i] : 0, at: i)
        }
        i += len
    }

    // MARK: - JSON5 scanners (reached only in `.json5` mode; strict/lenient paths are untouched)

    // JSON5 string: single- or double-quoted, the JSON5 escape set (incl. `\x`, `\v`, `\0`, and line
    // continuations), and unescaped line separators. UTF-8 is validated; bare control chars are
    // rejected. No SWAR fast path — the terminator may be `'` — since JSON5 is an opt-in convenience
    // mode, not a throughput path.
    mutating func scanStringJSON5() throws(JSONError) {
        let quote = unsafe p[i]  // ' or "
        let start = i + 1
        var j = start
        var esc: UInt64 = 0
        while j < n {
            let c = unsafe p[j]
            if c == quote { break }
            if c == 0x5C {
                esc = 1
                try validateEscapeJSON5(&j)
                continue
            }
            if c < 0x20 { throw JSONError.invalidString(at: j) }
            if c >= 0x80 {
                j += try unsafe JSONUTF8.sequenceLength(p, j, n)
                continue
            }
            j += 1
        }
        guard j < n else { throw JSONError.unexpectedEndOfInput }
        let length = j - start
        guard length <= Slot.maxLength else { throw JSONError.documentTooLarge }
        slots.append(Slot.scalar(JSONKind.string.rawValue, offset: start, length: length, flags: esc))
        i = j + 1
    }

    // `p[j]` is a backslash; validates a JSON5 escape and advances `j` past it (and the escaped char).
    mutating func validateEscapeJSON5(_ j: inout Int) throws(JSONError) {
        guard j + 1 < n else { throw JSONError.invalidString(at: j) }
        let e = unsafe p[j + 1]
        switch e {
            case 0x22, 0x27, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74, 0x76:  // " ' \ / b f n r t v
                j += 2
            case 0x30:  // \0 — NUL, only when not followed by a decimal digit
                if j + 2 < n, unsafe isDigit(p[j + 2]) { throw JSONError.invalidString(at: j) }
                j += 2
            case 0x31 ... 0x39:  // \1 … \9 are not valid JSON5 escapes
                throw JSONError.invalidString(at: j)
            case 0x78:  // \xHH
                guard j + 3 < n, unsafe Hex.value(p[j + 2]) != nil, unsafe Hex.value(p[j + 3]) != nil else {
                    throw JSONError.invalidString(at: j)
                }
                j += 4
            case 0x75:  // \uHHHH (with surrogate pairing), same shape as strict
                let high = try hex4(j + 2)
                if high >= 0xD800 && high <= 0xDBFF {
                    guard j + 7 < n, unsafe p[j + 6] == 0x5C, unsafe p[j + 7] == 0x75 else {
                        throw JSONError.invalidString(at: j)
                    }
                    let low = try hex4(j + 8)
                    guard low >= 0xDC00 && low <= 0xDFFF else { throw JSONError.invalidString(at: j) }
                    j += 12
                } else if high >= 0xDC00 && high <= 0xDFFF {
                    throw JSONError.invalidString(at: j)
                } else {
                    j += 6
                }
            case 0x0A:  // line continuation: \ + LF
                j += 2
            case 0x0D:  // line continuation: \ + CR (or CRLF)
                j += unsafe (j + 2 < n && p[j + 2] == 0x0A) ? 3 : 2
            default:
                // Identity escape (`\X` → `X`). The escaped scalar may be multi-byte (incl. the
                // U+2028/U+2029 line continuations), so validate and advance a full UTF-8 sequence.
                if e >= 0x80 {
                    j += 1
                    j += try unsafe JSONUTF8.sequenceLength(p, j, n)
                } else {
                    j += 2
                }
        }
    }

    // JSON5 unquoted object key: an ECMAScript IdentifierName (first char a letter / `_` / `$` /
    // non-ASCII; the rest also allowing digits). Recorded as an escape-free string slot.
    mutating func scanIdentifierKeyJSON5() throws(JSONError) {
        let start = i
        guard i < n, unsafe JSONString.isIdentStart(p[i]) else {
            throw JSONError.unexpectedCharacter(i < n ? unsafe p[i] : 0, at: i)
        }
        if unsafe p[i] >= 0x80 { i += try unsafe JSONUTF8.sequenceLength(p, i, n) } else { i += 1 }
        while i < n {
            let c = unsafe p[i]
            if c >= 0x80 {
                i += try unsafe JSONUTF8.sequenceLength(p, i, n)
            } else if JSONString.isIdentStart(c) || isDigit(c) {
                i += 1
            } else {
                break
            }
        }
        let length = i - start
        guard length <= Slot.maxLength else { throw JSONError.documentTooLarge }
        slots.append(Slot.scalar(JSONKind.string.rawValue, offset: start, length: length, flags: 0))
    }

    // JSON5 number: optional `+`/`-`, then `Infinity` / `NaN`, a hex integer (`0x…`), or a decimal
    // with optional leading/trailing dot and exponent. `isInt` is cleared for fractions, exponents,
    // and the non-finite literals; it stays set for plain and hex integers.
    mutating func scanNumberJSON5(_ isInt: inout UInt64, start: Int) throws(JSONError) {
        if i < n, unsafe p[i] == 0x2D || p[i] == 0x2B { i += 1 }  // sign
        guard i < n else { throw JSONError.invalidNumber(at: start) }
        if unsafe p[i] == 0x49 {  // 'I' → Infinity
            try expectLiteral("Infinity")
            isInt = 0
            return
        }
        if unsafe p[i] == 0x4E {  // 'N' → NaN
            try expectLiteral("NaN")
            isInt = 0
            return
        }
        if unsafe p[i] == 0x30, i + 1 < n, unsafe p[i + 1] == 0x78 || p[i + 1] == 0x58 {  // 0x / 0X
            i += 2
            let hexStart = i
            while i < n, unsafe Hex.value(p[i]) != nil { i += 1 }
            guard i > hexStart else { throw JSONError.invalidNumber(at: start) }
            return  // integer
        }
        var sawDigit = false
        while i < n, unsafe isDigit(p[i]) {
            i += 1
            sawDigit = true
        }
        if i < n, unsafe p[i] == 0x2E {  // '.'
            isInt = 0
            i += 1
            while i < n, unsafe isDigit(p[i]) {
                i += 1
                sawDigit = true
            }
        }
        guard sawDigit else { throw JSONError.invalidNumber(at: start) }
        if i < n, unsafe p[i] == 0x65 || p[i] == 0x45 {  // e / E
            isInt = 0
            i += 1
            if i < n, unsafe p[i] == 0x2B || p[i] == 0x2D { i += 1 }
            let expStart = i
            while i < n, unsafe isDigit(p[i]) { i += 1 }
            guard i > expStart else { throw JSONError.invalidNumber(at: start) }
        }
    }
}
