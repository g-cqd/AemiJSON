// Single-pass, iterative (explicit-stack, non-recursive) scanner that builds the tape
// WITHOUT materializing any value. In strict mode it enforces the RFC 8259 grammar (number
// shape, escape validity, UTF-8 well-formedness); in lenient mode it scans permissively.
struct TapeBuilder {
    let p: UnsafePointer<UInt8>
    let n: Int
    let strict: Bool
    let json5: Bool
    let checkDuplicates: Bool
    let enforceIEEE754Numbers: Bool
    let maxDepth: Int
    var i = 0
    var slots: ContiguousArray<UInt64>
    var stack: [Frame] = []

    // One open container being built. Stands in for a recursive-descent call frame, so nesting
    // lives on the heap and arbitrarily deep input can never overflow the call stack.
    //
    // `seenKeys` is initialized `[:]` for every frame, including arrays. An empty Swift dictionary
    // literal is the shared empty-singleton — it allocates nothing until the first insert, and only
    // `recordKey` (objects, in `.throwError` mode) ever inserts — so array frames and the default
    // (no duplicate-check) path pay zero allocation here. (Measured: already optimal; left as-is.)
    struct Frame {
        let openIndex: Int
        var count: Int
        let isObject: Bool
        var seenKeys: [Int: [(offset: Int, length: Int)]]
    }

    init(_ p: UnsafePointer<UInt8>, _ n: Int, options: JSONParseOptions) {
        self.p = p
        self.n = n
        self.strict = options.isStrict
        self.json5 = options.isJSON5
        self.checkDuplicates = options.duplicateKeys == .throwError
        self.enforceIEEE754Numbers = options.restrictsNumbersToIEEE754
        self.maxDepth = options.maxDepth
        self.slots = []
        slots.reserveCapacity(n / 4 + 8)
        stack.reserveCapacity(16)
    }

    mutating func build() throws(JSONError) -> ContiguousArray<UInt64> {
        skipWS()
        try parseValue()
        skipWS()
        if i != n { throw JSONError.trailingData(at: i) }
        return slots
    }

    // Scalar whitespace skip. A SWAR (word-at-a-time) variant was implemented and benchmarked but
    // *regressed* ~2.2× on realistic pretty-printed input (522 vs 1169 MB/s): JSON whitespace runs
    // are short (a newline + a few indent spaces), so the per-call word load + mask latency sits on
    // the parse critical path without the 8-bytes-at-a-time payoff, while this scalar loop is
    // branch-predictable and cache-resident. Kept scalar deliberately (measured, not assumed).
    @inline(__always) mutating func skipWS() {
        if json5 {
            skipWSAndCommentsJSON5()
            return
        }
        while i < n {
            let c = p[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 } else { break }
        }
    }

    // JSON5 insignificant input: the usual whitespace, vertical-tab / form-feed, and `//` line and
    // `/* … */` block comments. A lone `/` is left for the value parser to reject. An unterminated
    // block comment consumes to EOF, so the parser then reports an unexpected end of input.
    mutating func skipWSAndCommentsJSON5() {
        while i < n {
            let c = p[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0B || c == 0x0C {
                i += 1
                continue
            }
            guard c == 0x2F, i + 1 < n else { break }  // '/'
            if p[i + 1] == 0x2F {  // '//' line comment
                i += 2
                while i < n, p[i] != 0x0A, p[i] != 0x0D { i += 1 }
            } else if p[i + 1] == 0x2A {  // '/*' block comment
                i += 2
                while i + 1 < n, !(p[i] == 0x2A && p[i + 1] == 0x2F) { i += 1 }
                i = (i + 1 < n) ? i + 2 : n  // consume '*/', or run to EOF if unterminated
            } else {
                break  // lone '/'
            }
        }
    }

    // Iterative tape construction: an explicit `stack` of open containers replaces recursive
    // descent, so nesting costs heap (O(depth)) rather than call-stack frames and can't overflow
    // the stack at any depth. The emitted tape is byte-identical to the recursive version.
    mutating func parseValue() throws(JSONError) {
        while true {
            // Positioned at the start of a value.
            skipWS()
            guard i < n else { throw JSONError.unexpectedEndOfInput }
            let c = p[i]
            var completed: Bool
            switch c {
            case 0x7B:  // '{'
                if stack.count >= maxDepth { throw JSONError.depthExceeded(at: i) }
                let openIdx = slots.count
                slots.append(0)  // placeholder, patched at close
                i += 1
                skipWS()
                if i < n && p[i] == 0x7D {
                    i += 1
                    try closeContainer(openIdx, count: 0, isObject: true)
                    completed = true
                } else {
                    stack.append(Frame(openIndex: openIdx, count: 0, isObject: true, seenKeys: [:]))
                    try readKeyColon()
                    completed = false
                }
            case 0x5B:  // '['
                if stack.count >= maxDepth { throw JSONError.depthExceeded(at: i) }
                let openIdx = slots.count
                slots.append(0)
                i += 1
                skipWS()
                if i < n && p[i] == 0x5D {
                    i += 1
                    try closeContainer(openIdx, count: 0, isObject: false)
                    completed = true
                } else {
                    stack.append(Frame(openIndex: openIdx, count: 0, isObject: false, seenKeys: [:]))
                    completed = false
                }
            case 0x22:
                try scanString()
                completed = true
            case 0x74, 0x66, 0x6E:
                try scanLiteral()
                completed = true
            case 0x2D, 0x30...0x39:
                try scanNumber()
                completed = true
            default:
                // JSON5 value starts: single-quoted string, leading `+`/`.`, and the `Infinity` /
                // `NaN` literals. Kept out of the strict/lenient dispatch above so it is unchanged.
                if json5, c == 0x27 {
                    try scanString()
                    completed = true
                } else if json5, c == 0x2B || c == 0x2E || c == 0x49 || c == 0x4E {  // + . I(nfinity) N(aN)
                    try scanNumber()
                    completed = true
                } else {
                    throw JSONError.unexpectedCharacter(c, at: i)
                }
            }

            // A value is complete: fold it into its parent, closing each container the input ends.
            while completed {
                guard !stack.isEmpty else { return }  // the completed value was the document root
                stack[stack.count - 1].count += 1
                skipWS()
                guard i < n else { throw JSONError.unexpectedEndOfInput }
                let sep = p[i]
                if stack[stack.count - 1].isObject {
                    if sep == 0x2C {
                        i += 1
                        // JSON5 trailing comma: a `,` directly before `}` closes the object.
                        if json5, trailingCommaClosesContainer(0x7D) {
                            let frame = stack.removeLast()
                            try closeContainer(frame.openIndex, count: frame.count, isObject: true)
                        } else {
                            try readKeyColon()
                            completed = false
                        }
                    } else if sep == 0x7D {
                        i += 1
                        let frame = stack.removeLast()
                        try closeContainer(frame.openIndex, count: frame.count, isObject: true)
                    } else {
                        throw JSONError.unexpectedCharacter(sep, at: i)
                    }
                } else if sep == 0x2C {
                    i += 1
                    // JSON5 trailing comma: a `,` directly before `]` closes the array.
                    if json5, trailingCommaClosesContainer(0x5D) {
                        let frame = stack.removeLast()
                        try closeContainer(frame.openIndex, count: frame.count, isObject: false)
                    } else {
                        completed = false
                    }
                } else if sep == 0x5D {
                    i += 1
                    let frame = stack.removeLast()
                    try closeContainer(frame.openIndex, count: frame.count, isObject: false)
                } else {
                    throw JSONError.unexpectedCharacter(sep, at: i)
                }
            }
        }
    }

    // JSON5: after a comma, peek past whitespace/comments; if the next significant byte is the
    // container's closer, consume it (the comma was trailing) and report the container closed.
    mutating func trailingCommaClosesContainer(_ closer: UInt8) -> Bool {
        skipWS()
        if i < n, p[i] == closer {
            i += 1
            return true
        }
        return false
    }

    // Reads `"key":` for the current (top) object frame: key string + duplicate check + colon. In
    // JSON5 the key may also be single-quoted or an unquoted ECMAScript identifier.
    mutating func readKeyColon() throws(JSONError) {
        skipWS()
        let keyStart = i
        if json5, i < n, p[i] != 0x22, p[i] != 0x27 {
            try scanIdentifierKeyJSON5()  // unquoted identifier
        } else {
            guard i < n, p[i] == 0x22 || (json5 && p[i] == 0x27) else {
                throw JSONError.unexpectedCharacter(i < n ? p[i] : 0, at: i)
            }
            try scanString()  // quoted key ('…' handled in json5)
        }
        if checkDuplicates { try recordKey(keyStart, frame: stack.count - 1) }
        skipWS()
        guard i < n, p[i] == 0x3A else { throw JSONError.unexpectedCharacter(i < n ? p[i] : 0, at: i) }
        i += 1  // :
    }

    // Patches a container's placeholder with its element count and the index after its subtree.
    // `count` occupies the 28-bit aux field, `next` the low 32 bits — both bounded by the 4 GB
    // input cap, but guarded so a pathological count can't silently wrap and corrupt navigation.
    mutating func closeContainer(_ openIdx: Int, count: Int, isObject: Bool) throws(JSONError) {
        guard count <= Slot.auxMask, UInt64(slots.count) <= 0xFFFF_FFFF else { throw JSONError.documentTooLarge }
        let tag = isObject ? JSONKind.object.rawValue : JSONKind.array.rawValue
        slots[openIdx] = Slot.container(tag, count: count, next: slots.count)
    }

    // Detects duplicate keys (RFC 7493 / `.throwError`) in O(1) expected time by bucketing keys
    // under a hash of their raw bytes — avoiding the O(n²) all-pairs scan a hostile object with
    // many keys could exploit (DoS). Hash collisions fall back to a byte compare.
    //
    // The hash is Swift's `Hasher` (SipHash), seeded randomly per process, so an attacker cannot
    // precompute a flood of colliding keys to force the O(bucket²) fallback — the fixed-seed FNV-1a
    // this replaced was vulnerable to exactly that HashDoS.
    //
    // NOTE: keys are compared by their RAW (still-escaped) bytes, so two keys equal only after
    // unescaping (`"a"` vs `"a"`) are NOT reported as duplicates. This is a deliberate perf
    // tradeoff — no per-key unescape on the scan path — and is acceptable under RFC 8259 (which
    // leaves duplicate handling to the application); RFC 7493 I-JSON producers emit canonical keys.
    mutating func recordKey(_ keyStart: Int, frame: Int) throws(JSONError) {
        let keySlot = slots[slots.count - 1]
        let offset = Slot.low(keySlot)
        let length = Slot.length(keySlot)
        var hasher = Hasher()
        hasher.combine(bytes: UnsafeRawBufferPointer(start: p + offset, count: length))
        let hash = hasher.finalize()
        // Read the bucket for the collision check, then append in place. The `if let` binding is
        // released before the `default:` subscript mutates, so the stored array keeps refcount 1 and
        // the append doesn't copy-on-write the whole bucket on every key.
        if let bucket = stack[frame].seenKeys[hash] {
            for previous in bucket
            where previous.length == length
                && (length == 0 || JSONKey.bytesEqual(p + previous.offset, p + offset, length))
            {
                throw JSONError.duplicateKey(at: keyStart)
            }
        }
        stack[frame].seenKeys[hash, default: []].append((offset, length))
    }

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
                let word = UInt64(littleEndian: UnsafeRawPointer(p + j).loadUnaligned(as: UInt64.self))
                let mask = Self.stringStopMask(word)
                if mask == 0 {
                    j += 8
                    continue
                }
                j += mask.trailingZeroBitCount >> 3  // first stop byte (its 0x80 bit, /8)
                break
            }
            guard j < n else { break }
            let c = p[j]
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
                    j += try JSONUTF8.sequenceLength(p, j, n)
                } while j < n && p[j] >= 0x80
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
        let ones: UInt64 = 0x0101_0101_0101_0101
        let high: UInt64 = 0x8080_8080_8080_8080
        let lessThan0x20 = (v &- (ones &* 0x20)) & ~v & high  // bytes < 0x20
        let nonASCII = v & high  // bytes >= 0x80
        let quote = v ^ (ones &* 0x22)  // zero byte where v == '"'
        let isQuote = (quote &- ones) & ~quote & high
        let backslash = v ^ (ones &* 0x5C)  // zero byte where v == '\'
        let isBackslash = (backslash &- ones) & ~backslash & high
        return lessThan0x20 | nonASCII | isQuote | isBackslash
    }

    // `p[j]` is a backslash; validates the escape and advances `j` past it.
    mutating func validateEscape(_ j: inout Int) throws(JSONError) {
        guard j + 1 < n else { throw JSONError.invalidString(at: j) }
        switch p[j + 1] {
        case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
            j += 2
        case 0x75:  // \uXXXX
            let high = try hex4(j + 2)
            if high >= 0xD800 && high <= 0xDBFF {
                guard j + 7 < n, p[j + 6] == 0x5C, p[j + 7] == 0x75 else { throw JSONError.invalidString(at: j) }
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

    func hex4(_ at: Int) throws(JSONError) -> UInt16 {
        guard at + 4 <= n else { throw JSONError.invalidString(at: at) }
        var value: UInt16 = 0
        for k in 0..<4 {
            guard let digit = hexValue(p[at + k]) else { throw JSONError.invalidString(at: at) }
            value = (value << 4) | UInt16(digit)
        }
        return value
    }

    @inline(__always) func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x61...0x66: return b - 0x61 + 10
        case 0x41...0x46: return b - 0x41 + 10
        default: return nil
        }
    }

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
            if i < n && (p[i] == 0x2D || p[i] == 0x2B) { i += 1 }
            let intStart = i
            while i < n && isDigit(p[i]) { i += 1 }
            var sawDigits = i > intStart
            if i < n && p[i] == 0x2E {
                isInt = 0
                i += 1
                let fracStart = i
                while i < n && isDigit(p[i]) { i += 1 }
                sawDigits = sawDigits || i > fracStart
            }
            guard sawDigits else { throw JSONError.invalidNumber(at: start) }
            if i < n && (p[i] == 0x65 || p[i] == 0x45) {
                isInt = 0
                i += 1
                if i < n && (p[i] == 0x2B || p[i] == 0x2D) { i += 1 }
                let expStart = i
                while i < n && isDigit(p[i]) { i += 1 }
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
            guard let value = JSONNumber.parseInteger(p, start, length, Int64.self),
                value >= -9_007_199_254_740_991, value <= 9_007_199_254_740_991
            else { throw JSONError.invalidNumber(at: start) }
        } else if !JSONNumber.parseDouble(p, start, length).isFinite {
            throw JSONError.invalidNumber(at: start)
        }
    }

    // RFC 8259: [ '-' ] ( '0' | [1-9][0-9]* ) [ '.' [0-9]+ ] [ (e|E) [+|-] [0-9]+ ]
    mutating func scanNumberStrict(_ isInt: inout UInt64, start: Int) throws(JSONError) {
        if i < n && p[i] == 0x2D { i += 1 }
        guard i < n else { throw JSONError.invalidNumber(at: start) }
        if p[i] == 0x30 {
            i += 1
            if i < n && isDigit(p[i]) { throw JSONError.invalidNumber(at: start) }  // no leading zero
        } else if p[i] >= 0x31 && p[i] <= 0x39 {
            i += 1
            while i < n && isDigit(p[i]) { i += 1 }
        } else {
            throw JSONError.invalidNumber(at: start)
        }
        if i < n && p[i] == 0x2E {
            isInt = 0
            i += 1
            guard i < n && isDigit(p[i]) else { throw JSONError.invalidNumber(at: start) }
            while i < n && isDigit(p[i]) { i += 1 }
        }
        if i < n && (p[i] == 0x65 || p[i] == 0x45) {
            isInt = 0
            i += 1
            if i < n && (p[i] == 0x2B || p[i] == 0x2D) { i += 1 }
            guard i < n && isDigit(p[i]) else { throw JSONError.invalidNumber(at: start) }
            while i < n && isDigit(p[i]) { i += 1 }
        }
    }

    @inline(__always) func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    mutating func scanLiteral() throws(JSONError) {
        let start = i
        switch p[i] {
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
        guard i + len <= n, JSONKey.bytesEqual(p + i, lit.utf8Start, len) else {
            throw JSONError.unexpectedCharacter(i < n ? p[i] : 0, at: i)
        }
        i += len
    }

    // MARK: - JSON5 scanners (reached only in `.json5` mode; strict/lenient paths are untouched)

    // JSON5 string: single- or double-quoted, the JSON5 escape set (incl. `\x`, `\v`, `\0`, and line
    // continuations), and unescaped line separators. UTF-8 is validated; bare control chars are
    // rejected. No SWAR fast path — the terminator may be `'` — since JSON5 is an opt-in convenience
    // mode, not a throughput path.
    mutating func scanStringJSON5() throws(JSONError) {
        let quote = p[i]  // ' or "
        let start = i + 1
        var j = start
        var esc: UInt64 = 0
        while j < n {
            let c = p[j]
            if c == quote { break }
            if c == 0x5C {
                esc = 1
                try validateEscapeJSON5(&j)
                continue
            }
            if c < 0x20 { throw JSONError.invalidString(at: j) }
            if c >= 0x80 {
                j += try JSONUTF8.sequenceLength(p, j, n)
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
        let e = p[j + 1]
        switch e {
        case 0x22, 0x27, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74, 0x76:  // " ' \ / b f n r t v
            j += 2
        case 0x30:  // \0 — NUL, only when not followed by a decimal digit
            if j + 2 < n, isDigit(p[j + 2]) { throw JSONError.invalidString(at: j) }
            j += 2
        case 0x31...0x39:  // \1 … \9 are not valid JSON5 escapes
            throw JSONError.invalidString(at: j)
        case 0x78:  // \xHH
            guard j + 3 < n, hexValue(p[j + 2]) != nil, hexValue(p[j + 3]) != nil else {
                throw JSONError.invalidString(at: j)
            }
            j += 4
        case 0x75:  // \uHHHH (with surrogate pairing), same shape as strict
            let high = try hex4(j + 2)
            if high >= 0xD800 && high <= 0xDBFF {
                guard j + 7 < n, p[j + 6] == 0x5C, p[j + 7] == 0x75 else { throw JSONError.invalidString(at: j) }
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
            j += (j + 2 < n && p[j + 2] == 0x0A) ? 3 : 2
        default:
            // Identity escape (`\X` → `X`). The escaped scalar may be multi-byte (incl. the
            // U+2028/U+2029 line continuations), so validate and advance a full UTF-8 sequence.
            if e >= 0x80 {
                j += 1
                j += try JSONUTF8.sequenceLength(p, j, n)
            } else {
                j += 2
            }
        }
    }

    // JSON5 unquoted object key: an ECMAScript IdentifierName (first char a letter / `_` / `$` /
    // non-ASCII; the rest also allowing digits). Recorded as an escape-free string slot.
    mutating func scanIdentifierKeyJSON5() throws(JSONError) {
        let start = i
        guard i < n, isIdentStart(p[i]) else { throw JSONError.unexpectedCharacter(i < n ? p[i] : 0, at: i) }
        if p[i] >= 0x80 { i += try JSONUTF8.sequenceLength(p, i, n) } else { i += 1 }
        while i < n {
            let c = p[i]
            if c >= 0x80 {
                i += try JSONUTF8.sequenceLength(p, i, n)
            } else if isIdentStart(c) || isDigit(c) {
                i += 1
            } else {
                break
            }
        }
        let length = i - start
        guard length <= Slot.maxLength else { throw JSONError.documentTooLarge }
        slots.append(Slot.scalar(JSONKind.string.rawValue, offset: start, length: length, flags: 0))
    }

    @inline(__always) func isIdentStart(_ b: UInt8) -> Bool {
        ((b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A) || b == 0x5F || b == 0x24 || b >= 0x80
    }

    // JSON5 number: optional `+`/`-`, then `Infinity` / `NaN`, a hex integer (`0x…`), or a decimal
    // with optional leading/trailing dot and exponent. `isInt` is cleared for fractions, exponents,
    // and the non-finite literals; it stays set for plain and hex integers.
    mutating func scanNumberJSON5(_ isInt: inout UInt64, start: Int) throws(JSONError) {
        if i < n, p[i] == 0x2D || p[i] == 0x2B { i += 1 }  // sign
        guard i < n else { throw JSONError.invalidNumber(at: start) }
        if p[i] == 0x49 {  // 'I' → Infinity
            try expectLiteral("Infinity")
            isInt = 0
            return
        }
        if p[i] == 0x4E {  // 'N' → NaN
            try expectLiteral("NaN")
            isInt = 0
            return
        }
        if p[i] == 0x30, i + 1 < n, p[i + 1] == 0x78 || p[i + 1] == 0x58 {  // 0x / 0X
            i += 2
            let hexStart = i
            while i < n, hexValue(p[i]) != nil { i += 1 }
            guard i > hexStart else { throw JSONError.invalidNumber(at: start) }
            return  // integer
        }
        var sawDigit = false
        while i < n, isDigit(p[i]) {
            i += 1
            sawDigit = true
        }
        if i < n, p[i] == 0x2E {  // '.'
            isInt = 0
            i += 1
            while i < n, isDigit(p[i]) {
                i += 1
                sawDigit = true
            }
        }
        guard sawDigit else { throw JSONError.invalidNumber(at: start) }
        if i < n, p[i] == 0x65 || p[i] == 0x45 {  // e / E
            isInt = 0
            i += 1
            if i < n, p[i] == 0x2B || p[i] == 0x2D { i += 1 }
            let expStart = i
            while i < n, isDigit(p[i]) { i += 1 }
            guard i > expStart else { throw JSONError.invalidNumber(at: start) }
        }
    }
}
