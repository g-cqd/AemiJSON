/// An error from parsing an RFC 9535 JSONPath expression, located by UTF-8 byte `position`.
public struct JSONPathError: Error, Sendable, Equatable {
    public let message: String
    public let position: Int
}

// Byte-oriented RFC 9535 parser (mirrors `SQLiteJSONPath.Parser`): the query is scanned over its
// UTF-8 `[UInt8]` rather than a decoded `[Character]`, so member names / quoted strings accumulate
// raw bytes (any byte ≥ 0x80 is a name/content continuation) and decode to `String` only at the
// token boundary. Error `position` is a byte index. The RFC 9535 compliance suite (CTS) is the
// behavioural safety net for this conversion.
struct JSONPathParser {
    let bytes: [UInt8]
    var i = 0
    // Bounds the parser's structural recursion (parenthesised filter sub-expressions and nested
    // bracket-filters / relative queries) so a crafted query (`((((…))))`, `[?@[?@[?…]]]`) can't
    // exhaust the stack. `depth` is incremented at the two mutual-recursion entry points below
    // (`parseSegments`, `parsePrimary`) and also bounds `evalFilter`'s walk of the resulting AST.
    //
    // The cap is deliberately small: each nesting level costs ~3 KB of native stack, so the former
    // 256 overflowed a 512 KB secondary-thread stack (the realistic floor off the main thread) at
    // ~160 levels — before the guard could fire. The RFC 9535 compliance suite never nests deeper
    // than 3, so 64 keeps a 20× headroom over any real query while staying well inside a small
    // stack (~205 KB worst case); anything deeper is pathological and is rejected, not crashed.
    var depth = 0
    static let maxDepth = 64
    // Monotonic counter handing every `RelQuery` a stable id (see `RelQuery.id`) for filter caching.
    var relQueryCount = 0

    init(_ s: String) { bytes = Array(s.utf8) }

    mutating func enter() throws(JSONPathError) {
        depth += 1
        guard depth <= Self.maxDepth else { throw err("expression nested too deeply") }
    }

    var atEnd: Bool { i >= bytes.count }
    func peek() -> UInt8? { i < bytes.count ? bytes[i] : nil }
    func peek2() -> UInt8? { i + 1 < bytes.count ? bytes[i + 1] : nil }
    func err(_ m: String) -> JSONPathError { JSONPathError(message: m, position: i) }

    @inline(__always) func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    @inline(__always) func isAlpha(_ b: UInt8) -> Bool { (b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A }
    // RFC 9535 member-name-shorthand: name-first = ALPHA / "_" / non-ASCII (NOT a digit); a
    // subsequent name-char additionally allows DIGIT. In UTF-8 any byte ≥ 0x80 is part of a
    // (non-ASCII) scalar, so it is accepted verbatim and decoded with the rest of the name.
    @inline(__always) func isNameFirst(_ b: UInt8) -> Bool { isAlpha(b) || b == 0x5F || b >= 0x80 }
    @inline(__always) func isNameChar(_ b: UInt8) -> Bool { isNameFirst(b) || isDigit(b) }
    @inline(__always) func isWS(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
    func describe(_ b: UInt8) -> String { String(UnicodeScalar(b)) }

    mutating func skipWS() {
        while i < bytes.count, isWS(bytes[i]) { i += 1 }
    }

    mutating func expect(_ b: UInt8) throws(JSONPathError) {
        skipWS()
        guard peek() == b else { throw err("expected '\(describe(b))'") }
        i += 1
    }

    mutating func parseRoot() throws(JSONPathError) -> [PathSegment] {
        // RFC 9535: `jsonpath-query = root-identifier segments` — no leading or trailing whitespace
        // around the whole query (inter-segment whitespace is handled in `parseSegments`).
        guard peek() == 0x24 else { throw err("path must start with $") }  // '$'
        i += 1
        let segs = try parseSegments()
        guard atEnd else { throw err("unexpected trailing characters") }
        return segs
    }

    mutating func parseSegments() throws(JSONPathError) -> [PathSegment] {
        try enter()
        defer { depth -= 1 }
        var segs: [PathSegment] = []
        // `segments = *(S segment)`: whitespace may precede a segment but is not consumed when no
        // segment follows, so a trailing run of whitespace is left for `parseRoot` to reject.
        while true {
            let save = i
            skipWS()
            guard let c = peek() else {
                i = save
                break
            }
            if c == 0x2E {  // '.'
                if peek2() == 0x2E {  // '..'
                    i += 2
                    segs.append(.descendant(try parseAfterDescendant()))
                } else {
                    i += 1
                    segs.append(.child([try parseDotSelector()]))
                }
            } else if c == 0x5B {  // '['
                segs.append(.child(try parseBracket()))
            } else {
                i = save
                return segs
            }
        }
        return segs
    }

    mutating func parseAfterDescendant() throws(JSONPathError) -> [Selector] {
        guard let c = peek() else { throw err("expected selector after '..'") }
        if c == 0x5B { return try parseBracket() }  // '['
        if c == 0x2A {  // '*'
            i += 1
            return [.wildcard]
        }
        return [.name(try parseMemberName())]
    }

    mutating func parseDotSelector() throws(JSONPathError) -> Selector {
        guard let c = peek() else { throw err("expected selector after '.'") }
        if c == 0x2A {  // '*'
            i += 1
            return .wildcard
        }
        return .name(try parseMemberName())
    }

    // RFC 9535 member-name-shorthand. Accumulates the raw name bytes (ASCII + any non-ASCII UTF-8
    // continuation) and decodes once at the boundary; the source is a valid `String`, so the decode
    // is lossless.
    mutating func parseMemberName() throws(JSONPathError) -> String {
        guard let first = peek(), isNameFirst(first) else { throw err("invalid member name") }
        var name: [UInt8] = [first]
        i += 1
        while let c = peek(), isNameChar(c) {
            name.append(c)
            i += 1
        }
        return String(decoding: name, as: UTF8.self)
    }

    mutating func parseBracket() throws(JSONPathError) -> [Selector] {
        try expect(0x5B)  // '['
        var sels: [Selector] = []
        repeat {
            skipWS()
            sels.append(try parseBracketSelector())
            skipWS()
        } while consumeComma()
        try expect(0x5D)  // ']'
        return sels
    }

    mutating func consumeComma() -> Bool {
        skipWS()
        if peek() == 0x2C {  // ','
            i += 1
            return true
        }
        return false
    }

    mutating func parseBracketSelector() throws(JSONPathError) -> Selector {
        skipWS()
        guard let c = peek() else { throw err("expected selector") }
        if c == 0x2A {  // '*'
            i += 1
            return .wildcard
        }
        if c == 0x3F {  // '?'
            i += 1
            return .filter(try parseFilter())
        }
        if c == 0x27 || c == 0x22 { return .name(try parseQuotedString()) }  // ' or "
        return try parseIndexOrSlice()
    }

    // A number component is parsed only when one is actually present (starts with `-`/digit); when
    // present it must be a valid RFC 9535 `int`, so e.g. `[01]` or `[::01]` is rejected rather than
    // silently treated as a default.
    mutating func parseIndexOrSlice() throws(JSONPathError) -> Selector {
        skipWS()
        var first: Int? = nil
        if isIntStart(peek()) { first = try parseInt() }
        skipWS()
        if peek() == 0x3A {  // ':'
            i += 1
            skipWS()
            var end: Int? = nil
            if isIntStart(peek()) { end = try parseInt() }
            skipWS()
            var step = 1
            if peek() == 0x3A {  // ':'
                i += 1
                skipWS()
                if isIntStart(peek()) { step = try parseInt() }
            }
            return .slice(start: first, end: end, step: step)
        }
        guard let idx = first else { throw err("expected index or slice") }
        return .index(idx)
    }

    func isIntStart(_ b: UInt8?) -> Bool {
        guard let b else { return false }
        return b == 0x2D || isDigit(b)  // '-' or DIGIT
    }

    // RFC 9535 `int = "0" / (["-"] DIGIT1 *DIGIT)`: no leading zeros, no `-0`, and the I-JSON range
    // [-(2^53-1), 2^53-1]. Out-of-range or malformed digits are rejected.
    mutating func parseInt() throws(JSONPathError) -> Int {
        var neg = false
        if peek() == 0x2D {  // '-'
            neg = true
            i += 1
        }
        guard let first = peek(), isDigit(first) else { throw err("expected digit in index") }
        if first == 0x30 {  // '0'
            i += 1
            if neg { throw err("negative zero index") }
            if let c = peek(), isDigit(c) { throw err("leading zero in index") }
            return 0
        }
        var digits: [UInt8] = [first]
        i += 1
        while let c = peek(), isDigit(c) {
            digits.append(c)
            i += 1
        }
        // Parse the magnitude as Int64 — 64-bit on every platform, so the 2^53-1 bound is
        // representable even on 32-bit watchOS (arm64_32) — then narrow to Int. On a 32-bit
        // platform an index beyond Int.max is rejected here, since it can't be represented or used
        // to subscript anyway.
        guard let magnitude = Int64(String(decoding: digits, as: UTF8.self)), magnitude <= 9_007_199_254_740_991,
            let signed = Int(exactly: neg ? -magnitude : magnitude)
        else { throw err("index out of range") }
        return signed
    }

    // RFC 9535 §2.3.1.1 string-literal: the active quote closes; `\` introduces an escape; bare
    // control characters (< U+0020) are rejected; only the documented escapes are allowed (the
    // opposite quote may NOT be backslash-escaped). `\u` requires exactly four hex digits with
    // correct surrogate pairing. Content bytes (including multi-byte UTF-8) accumulate raw.
    mutating func parseQuotedString() throws(JSONPathError) -> String {
        let quote = bytes[i]  // ' or "
        i += 1
        var out: [UInt8] = []
        while let c = peek() {
            if c == quote {
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if c == 0x5C {  // '\'
                i += 1
                guard let e = peek() else { throw err("unterminated escape") }
                i += 1
                switch e {
                case 0x62: out.append(0x08)  // \b
                case 0x66: out.append(0x0C)  // \f
                case 0x6E: out.append(0x0A)  // \n
                case 0x72: out.append(0x0D)  // \r
                case 0x74: out.append(0x09)  // \t
                case 0x2F: out.append(0x2F)  // \/
                case 0x5C: out.append(0x5C)  // \\
                case quote: out.append(quote)  // \" only in "…", \' only in '…'
                case 0x75: out.append(contentsOf: Array(String(try parseUnicodeEscape()).utf8))  // \uXXXX
                default: throw err("invalid escape '\\\(describe(e))'")
                }
                continue
            }
            if c < 0x20 { throw err("unescaped control character") }  // all controls are ASCII
            out.append(c)
            i += 1
        }
        throw err("unterminated string")
    }

    // `\uXXXX`, combining a high+low surrogate pair into one scalar; lone/mismatched surrogates are
    // rejected. The leading `u` has already been consumed.
    mutating func parseUnicodeEscape() throws(JSONPathError) -> Unicode.Scalar {
        let hi = try hex4()
        if (0xD800...0xDBFF).contains(hi) {
            guard peek() == 0x5C, peek2() == 0x75 else { throw err("lone high surrogate") }  // '\' 'u'
            i += 2
            let lo = try hex4()
            guard (0xDC00...0xDFFF).contains(lo) else { throw err("invalid low surrogate") }
            let combined = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
            guard let us = Unicode.Scalar(combined) else { throw err("invalid code point") }
            return us
        }
        if (0xDC00...0xDFFF).contains(hi) { throw err("lone low surrogate") }
        guard let us = Unicode.Scalar(hi) else { throw err("invalid code point") }
        return us
    }

    mutating func hex4() throws(JSONPathError) -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 {
            guard let c = peek(), let d = hexValue(c) else { throw err("invalid \\u escape") }
            v = (v << 4) | d
            i += 1
        }
        return v
    }

    @inline(__always) func hexValue(_ b: UInt8) -> UInt32? {
        switch b {
        case 0x30...0x39: return UInt32(b - 0x30)
        case 0x41...0x46: return UInt32(b - 0x41 + 10)
        case 0x61...0x66: return UInt32(b - 0x61 + 10)
        default: return nil
        }
    }

    // MARK: - Filter expressions

    // Design note (intentional skip): the filter grammar is a hand-written precedence-climbing
    // recursive descent (`parseOr` → `parseAnd` → `parseNot` → `parsePrimary` → `parseComparand`),
    // NOT a Pratt parser / PDA. A Pratt rewrite was considered and deliberately not done: the only
    // recursion here is structural (parenthesised sub-expressions and nested bracket-filters), and it
    // is already bounded by `enter()` / `maxDepth` (64) and proven stack-safe — `&&`/`||` iterate and
    // `!` folds by parity, so there is no unbounded recursion left for a rewrite to remove. It would
    // be cosmetic and risk a CTS regression for no safety or correctness gain.
    mutating func parseFilter() throws(JSONPathError) -> FilterExpr { try parseOr() }

    mutating func parseOr() throws(JSONPathError) -> FilterExpr {
        var terms = [try parseAnd()]
        while true {
            skipWS()
            if peek() == 0x7C, peek2() == 0x7C {  // '||'
                i += 2
                terms.append(try parseAnd())
            } else {
                break
            }
        }
        return terms.count == 1 ? terms[0] : .or(terms)
    }

    mutating func parseAnd() throws(JSONPathError) -> FilterExpr {
        var terms = [try parseNot()]
        while true {
            skipWS()
            if peek() == 0x26, peek2() == 0x26 {  // '&&'
                i += 2
                terms.append(try parseNot())
            } else {
                break
            }
        }
        return terms.count == 1 ? terms[0] : .and(terms)
    }

    mutating func parseNot() throws(JSONPathError) -> FilterExpr {
        // Consume the whole run of leading `!` iteratively, tracking parity, so a crafted
        // `[?!!!…!@]` (200k `!`) can't recurse one frame per `!` and overflow the stack.
        // `!!x ≡ x`, so only an odd count negates; this is semantically identical to the
        // former per-`!` recursion but runs in O(1) stack.
        skipWS()
        var negate = false
        while peek() == 0x21 {  // '!'
            negate.toggle()
            i += 1
            skipWS()
        }
        let primary = try parsePrimary()
        return negate ? .not(primary) : primary
    }

    mutating func parsePrimary() throws(JSONPathError) -> FilterExpr {
        try enter()
        defer { depth -= 1 }
        skipWS()
        if peek() == 0x28 {  // '('
            i += 1
            let e = try parseOr()
            try expect(0x29)  // ')'
            return e
        }
        if let fn = peekIdentifier(), fn == "match" || fn == "search" {
            consumeIdentifier(fn)
            try expectFunctionParen()
            let a = try parseComparand()
            try expect(0x2C)  // ','
            let b = try parseComparand()
            try expect(0x29)  // ')'
            guard a.isValueType, b.isValueType else { throw err("match()/search() require value-type arguments") }
            return .regex(a, pattern: try compileRegexOperand(b), anchored: fn == "match")
        }
        let left = try parseComparand()
        if let op = parseCompOp() {
            let right = try parseComparand()
            guard left.isValueType, right.isValueType else {
                throw err("comparison operand must be a literal, singular query, or function")
            }
            return .comparison(left, op, right)
        }
        if case let .query(q) = left { return .existence(q) }
        throw err("expected comparison or existence test")
    }

    // A string-literal pattern is known now, so validate it against the I-Regexp safe subset and
    // compile it once here — closing the ReDoS hole before any JSON is seen and avoiding an O(N)
    // recompile per filtered node. A non-literal pattern (a query/function result) is untrusted
    // until evaluation, so it is deferred and re-checked per node there.
    mutating func compileRegexOperand(_ b: Comparand) throws(JSONPathError) -> RegexOperand {
        guard case let .literal(.string(pat)) = b else { return .dynamic(b) }
        if let reason = JSONPathEvaluator.iRegexpRejectionReason(pat) { throw err(reason) }
        guard let re = try? Regex(JSONPathEvaluator.iRegexpToSwift(pat)) else {
            throw err("invalid regular expression in match()/search()")
        }
        return .compiled(CompiledRegex(re))
    }

    // Peeks an ASCII identifier (the only function / keyword names RFC 9535 defines), skipping just
    // leading spaces — a tab/newline before it makes this return `nil`.
    func peekIdentifier() -> String? {
        var j = i
        while j < bytes.count, bytes[j] == 0x20 { j += 1 }  // ' '
        let start = j
        while j < bytes.count, isAlpha(bytes[j]) { j += 1 }
        return j > start ? String(decoding: bytes[start..<j], as: UTF8.self) : nil
    }

    mutating func consumeIdentifier(_ s: String) {
        skipWS()
        i += s.utf8.count
    }

    // RFC 9535: a function name is immediately followed by `(` — no whitespace between.
    mutating func expectFunctionParen() throws(JSONPathError) {
        guard peek() == 0x28 else { throw err("no whitespace allowed before '('") }  // '('
        i += 1
    }

    mutating func parseCompOp() -> CompOp? {
        skipWS()
        guard let c = peek() else { return nil }
        let d = peek2()
        if c == 0x3D, d == 0x3D {  // '=='
            i += 2
            return .eq
        }
        if c == 0x21, d == 0x3D {  // '!='
            i += 2
            return .ne
        }
        if c == 0x3C, d == 0x3D {  // '<='
            i += 2
            return .le
        }
        if c == 0x3E, d == 0x3D {  // '>='
            i += 2
            return .ge
        }
        if c == 0x3C {  // '<'
            i += 1
            return .lt
        }
        if c == 0x3E {  // '>'
            i += 1
            return .gt
        }
        return nil
    }

    mutating func parseComparand() throws(JSONPathError) -> Comparand {
        // `length()` takes a comparand argument, so `length(length(…(@)…))` recurses here once per
        // level; without this guard a crafted nest would overflow the parser stack (and the AST it
        // builds would then overflow `evalComparand`'s `.length` walk). `enter()`/`maxDepth` bounds
        // it exactly as it bounds `parseSegments`/`parsePrimary`.
        try enter()
        defer { depth -= 1 }
        skipWS()
        guard let c = peek() else { throw err("expected comparand") }
        if c == 0x40 || c == 0x24 { return .query(try parseRelQuery()) }  // '@' or '$'
        if let fn = peekIdentifier(), fn == "length" || fn == "count" || fn == "value" {
            consumeIdentifier(fn)
            try expectFunctionParen()
            let result: Comparand
            if fn == "length" {
                // length() takes a ValueType argument (literal, singular query, or function).
                let arg = try parseComparand()
                guard arg.isValueType else { throw err("length() requires a value-type argument") }
                result = .length(arg)
            } else {
                // count()/value() take a NodesType argument: any query.
                let q = try parseRelQuery()
                result = fn == "count" ? .count(q) : .value(q)
            }
            try expect(0x29)  // ')'
            return result
        }
        if c == 0x27 || c == 0x22 { return .literal(.string(try parseQuotedString())) }  // ' or "
        if c == 0x2D || isDigit(c) { return .literal(.number(try parseNumber())) }  // '-' or DIGIT
        if let id = peekIdentifier() {
            switch id {
            case "true":
                consumeIdentifier(id)
                return .literal(.bool(true))
            case "false":
                consumeIdentifier(id)
                return .literal(.bool(false))
            case "null":
                consumeIdentifier(id)
                return .literal(.null)
            default: break
            }
        }
        throw err("invalid comparand")
    }

    mutating func parseRelQuery() throws(JSONPathError) -> RelQuery {
        skipWS()
        guard peek() == 0x40 || peek() == 0x24 else { throw err("expected '@' or '$'") }  // '@' or '$'
        let fromRoot = peek() == 0x24
        i += 1
        let id = relQueryCount
        relQueryCount += 1
        let segs = try parseSegments()
        return RelQuery(id: id, fromRoot: fromRoot, segments: segs)
    }

    // RFC 9535 `number = (int / "-0") [ frac ] [ exp ]`: a leading-zero-free integer part (but `-0`
    // is allowed for numbers), an optional fraction with at least one digit, and an optional
    // exponent with at least one digit. `00`, `01`, `1.`, `1.e1`, `-.1` are all rejected.
    mutating func parseNumber() throws(JSONPathError) -> Double {
        skipWS()
        var s: [UInt8] = []
        if peek() == 0x2D {  // '-'
            s.append(0x2D)
            i += 1
        }
        guard let first = peek(), isDigit(first) else { throw err("expected digit in number") }
        if first == 0x30 {  // '0'
            s.append(0x30)
            i += 1
            if let c = peek(), isDigit(c) { throw err("leading zero in number") }
        } else {
            while let c = peek(), isDigit(c) {
                s.append(c)
                i += 1
            }
        }
        if peek() == 0x2E {  // '.'
            s.append(0x2E)
            i += 1
            guard let c = peek(), isDigit(c) else { throw err("missing fraction digits") }
            while let d = peek(), isDigit(d) {
                s.append(d)
                i += 1
            }
        }
        if peek() == 0x65 || peek() == 0x45 {  // 'e' / 'E'
            s.append(0x65)
            i += 1
            if let sign = peek(), sign == 0x2B || sign == 0x2D {  // '+' / '-'
                s.append(sign)
                i += 1
            }
            guard let c = peek(), isDigit(c) else { throw err("missing exponent digits") }
            while let d = peek(), isDigit(d) {
                s.append(d)
                i += 1
            }
        }
        guard let v = Double(String(decoding: s, as: UTF8.self)) else { throw err("invalid number") }
        return v
    }
}
