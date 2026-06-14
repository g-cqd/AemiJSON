/// An error from parsing an RFC 9535 JSONPath expression, located by character `position`.
public struct JSONPathError: Error, Sendable, Equatable {
    public let message: String
    public let position: Int
}

struct JSONPathParser {
    let chars: [Character]
    var i = 0
    // Bounds recursive descent so a crafted query (`((((…))))`, `[?@[?@[?…]]]`) can't
    // exhaust the stack. Incremented at the two mutual-recursion entry points below.
    var depth = 0
    static let maxDepth = 256

    init(_ s: String) { chars = Array(s) }

    mutating func enter() throws(JSONPathError) {
        depth += 1
        guard depth <= Self.maxDepth else { throw err("expression nested too deeply") }
    }

    var atEnd: Bool { i >= chars.count }
    func peek() -> Character? { i < chars.count ? chars[i] : nil }
    func peek2() -> Character? { i + 1 < chars.count ? chars[i + 1] : nil }
    func err(_ m: String) -> JSONPathError { JSONPathError(message: m, position: i) }

    mutating func skipWS() {
        while i < chars.count, chars[i] == " " || chars[i] == "\t" || chars[i] == "\n" || chars[i] == "\r" { i += 1 }
    }

    mutating func expect(_ c: Character) throws(JSONPathError) {
        skipWS()
        guard peek() == c else { throw err("expected '\(c)'") }
        i += 1
    }

    mutating func parseRoot() throws(JSONPathError) -> [PathSegment] {
        // RFC 9535: `jsonpath-query = root-identifier segments` — no leading or trailing whitespace
        // around the whole query (inter-segment whitespace is handled in `parseSegments`).
        guard peek() == "$" else { throw err("path must start with $") }
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
            switch c {
            case ".":
                if peek2() == "." {
                    i += 2
                    segs.append(.descendant(try parseAfterDescendant()))
                } else {
                    i += 1
                    segs.append(.child([try parseDotSelector()]))
                }
            case "[":
                segs.append(.child(try parseBracket()))
            default:
                i = save
                return segs
            }
        }
        return segs
    }

    mutating func parseAfterDescendant() throws(JSONPathError) -> [Selector] {
        guard let c = peek() else { throw err("expected selector after '..'") }
        if c == "[" { return try parseBracket() }
        if c == "*" {
            i += 1
            return [.wildcard]
        }
        return [.name(try parseMemberName())]
    }

    mutating func parseDotSelector() throws(JSONPathError) -> Selector {
        guard let c = peek() else { throw err("expected selector after '.'") }
        if c == "*" {
            i += 1
            return .wildcard
        }
        return .name(try parseMemberName())
    }

    // RFC 9535 member-name-shorthand: name-first = ALPHA / "_" / non-ASCII (NOT a digit);
    // subsequent name-char additionally allows DIGIT.
    mutating func parseMemberName() throws(JSONPathError) -> String {
        func isNameFirst(_ c: Character) -> Bool {
            c.isLetter || c == "_" || (c.unicodeScalars.first?.value ?? 0) > 0x7F
        }
        guard let first = peek(), isNameFirst(first) else { throw err("invalid member name") }
        var name = String(first)
        i += 1
        while let c = peek(), isNameFirst(c) || c.isNumber {
            name.append(c)
            i += 1
        }
        return name
    }

    mutating func parseBracket() throws(JSONPathError) -> [Selector] {
        try expect("[")
        var sels: [Selector] = []
        repeat {
            skipWS()
            sels.append(try parseBracketSelector())
            skipWS()
        } while consumeComma()
        try expect("]")
        return sels
    }

    mutating func consumeComma() -> Bool {
        skipWS()
        if peek() == "," {
            i += 1
            return true
        }
        return false
    }

    mutating func parseBracketSelector() throws(JSONPathError) -> Selector {
        skipWS()
        guard let c = peek() else { throw err("expected selector") }
        if c == "*" {
            i += 1
            return .wildcard
        }
        if c == "?" {
            i += 1
            return .filter(try parseFilter())
        }
        if c == "'" || c == "\"" { return .name(try parseQuotedString()) }
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
        if peek() == ":" {
            i += 1
            skipWS()
            var end: Int? = nil
            if isIntStart(peek()) { end = try parseInt() }
            skipWS()
            var step = 1
            if peek() == ":" {
                i += 1
                skipWS()
                if isIntStart(peek()) { step = try parseInt() }
            }
            return .slice(start: first, end: end, step: step)
        }
        guard let idx = first else { throw err("expected index or slice") }
        return .index(idx)
    }

    func isIntStart(_ c: Character?) -> Bool {
        guard let c else { return false }
        return c == "-" || ("0"..."9").contains(c)
    }

    // RFC 9535 `int = "0" / (["-"] DIGIT1 *DIGIT)`: no leading zeros, no `-0`, and the I-JSON range
    // [-(2^53-1), 2^53-1]. Out-of-range or malformed digits are rejected.
    mutating func parseInt() throws(JSONPathError) -> Int {
        func isDigit(_ c: Character?) -> Bool { c.map { ("0"..."9").contains($0) } ?? false }
        var neg = false
        if peek() == "-" {
            neg = true
            i += 1
        }
        guard let first = peek(), isDigit(first) else { throw err("expected digit in index") }
        if first == "0" {
            i += 1
            if neg { throw err("negative zero index") }
            if isDigit(peek()) { throw err("leading zero in index") }
            return 0
        }
        var digits = String(first)
        i += 1
        while let c = peek(), isDigit(c) {
            digits.append(c)
            i += 1
        }
        guard let v = Int(digits), v <= 9_007_199_254_740_991 else { throw err("index out of range") }
        return neg ? -v : v
    }

    // RFC 9535 §2.3.1.1 string-literal: the active quote closes; `\` introduces an escape; bare
    // control characters (< U+0020) are rejected; only the documented escapes are allowed (the
    // opposite quote may NOT be backslash-escaped). `\u` requires exactly four hex digits with
    // correct surrogate pairing.
    mutating func parseQuotedString() throws(JSONPathError) -> String {
        let quote = chars[i]  // ' or "
        i += 1
        var s = ""
        while let c = peek() {
            if c == quote {
                i += 1
                return s
            }
            if c == "\\" {
                i += 1
                guard let e = peek() else { throw err("unterminated escape") }
                i += 1
                switch e {
                case "b": s.append("\u{08}")
                case "f": s.append("\u{0C}")
                case "n": s.append("\n")
                case "r": s.append("\r")
                case "t": s.append("\t")
                case "/": s.append("/")
                case "\\": s.append("\\")
                case quote: s.append(quote)  // \" only in "…", \' only in '…'
                case "u": s.unicodeScalars.append(try parseUnicodeEscape())
                default: throw err("invalid escape '\\\(e)'")
                }
                continue
            }
            if let a = c.asciiValue, a < 0x20 {  // unescaped control character
                throw err("unescaped control character")
            }
            s.append(c)
            i += 1
        }
        throw err("unterminated string")
    }

    // `\uXXXX`, combining a high+low surrogate pair into one scalar; lone/!mismatched surrogates
    // are rejected. The leading `u` has already been consumed.
    mutating func parseUnicodeEscape() throws(JSONPathError) -> Unicode.Scalar {
        let hi = try hex4()
        if (0xD800...0xDBFF).contains(hi) {
            guard peek() == "\\", peek2() == "u" else { throw err("lone high surrogate") }
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
            guard let c = peek(), let d = c.hexDigitValue else { throw err("invalid \\u escape") }
            v = (v << 4) | UInt32(d)
            i += 1
        }
        return v
    }

    // MARK: - Filter expressions

    mutating func parseFilter() throws(JSONPathError) -> FilterExpr { try parseOr() }

    mutating func parseOr() throws(JSONPathError) -> FilterExpr {
        var terms = [try parseAnd()]
        while true {
            skipWS()
            if peek() == "|", peek2() == "|" {
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
            if peek() == "&", peek2() == "&" {
                i += 2
                terms.append(try parseNot())
            } else {
                break
            }
        }
        return terms.count == 1 ? terms[0] : .and(terms)
    }

    mutating func parseNot() throws(JSONPathError) -> FilterExpr {
        skipWS()
        if peek() == "!" {
            i += 1
            return .not(try parseNot())
        }
        return try parsePrimary()
    }

    mutating func parsePrimary() throws(JSONPathError) -> FilterExpr {
        try enter()
        defer { depth -= 1 }
        skipWS()
        if peek() == "(" {
            i += 1
            let e = try parseOr()
            try expect(")")
            return e
        }
        if let fn = peekIdentifier(), fn == "match" || fn == "search" {
            consumeIdentifier(fn)
            try expectFunctionParen()
            let a = try parseComparand()
            try expect(",")
            let b = try parseComparand()
            try expect(")")
            guard a.isValueType, b.isValueType else { throw err("match()/search() require value-type arguments") }
            return .regex(a, pattern: b, anchored: fn == "match")
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

    func peekIdentifier() -> String? {
        var j = i
        while j < chars.count, chars[j] == " " { j += 1 }
        var s = ""
        while j < chars.count, chars[j].isLetter {
            s.append(chars[j])
            j += 1
        }
        return s.isEmpty ? nil : s
    }

    mutating func consumeIdentifier(_ s: String) {
        skipWS()
        i += s.count
    }

    // RFC 9535: a function name is immediately followed by `(` — no whitespace between.
    mutating func expectFunctionParen() throws(JSONPathError) {
        guard peek() == "(" else { throw err("no whitespace allowed before '('") }
        i += 1
    }

    mutating func parseCompOp() -> CompOp? {
        skipWS()
        guard let c = peek() else { return nil }
        let d = peek2()
        if c == "=" && d == "=" {
            i += 2
            return .eq
        }
        if c == "!" && d == "=" {
            i += 2
            return .ne
        }
        if c == "<" && d == "=" {
            i += 2
            return .le
        }
        if c == ">" && d == "=" {
            i += 2
            return .ge
        }
        if c == "<" {
            i += 1
            return .lt
        }
        if c == ">" {
            i += 1
            return .gt
        }
        return nil
    }

    mutating func parseComparand() throws(JSONPathError) -> Comparand {
        skipWS()
        guard let c = peek() else { throw err("expected comparand") }
        if c == "@" || c == "$" { return .query(try parseRelQuery()) }
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
            try expect(")")
            return result
        }
        if c == "'" || c == "\"" { return .literal(.string(try parseQuotedString())) }
        if c == "-" || ("0"..."9").contains(c) { return .literal(.number(try parseNumber())) }
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
        guard peek() == "@" || peek() == "$" else { throw err("expected '@' or '$'") }
        let fromRoot = peek() == "$"
        i += 1
        let segs = try parseSegments()
        return RelQuery(fromRoot: fromRoot, segments: segs)
    }

    // RFC 9535 `number = (int / "-0") [ frac ] [ exp ]`: a leading-zero-free integer part (but `-0`
    // is allowed for numbers), an optional fraction with at least one digit, and an optional
    // exponent with at least one digit. `00`, `01`, `1.`, `1.e1`, `-.1` are all rejected.
    mutating func parseNumber() throws(JSONPathError) -> Double {
        skipWS()
        func isDigit(_ c: Character?) -> Bool { c.map { ("0"..."9").contains($0) } ?? false }
        var s = ""
        if peek() == "-" {
            s.append("-")
            i += 1
        }
        guard let first = peek(), isDigit(first) else { throw err("expected digit in number") }
        if first == "0" {
            s.append("0")
            i += 1
            if isDigit(peek()) { throw err("leading zero in number") }
        } else {
            while let c = peek(), isDigit(c) {
                s.append(c)
                i += 1
            }
        }
        if peek() == "." {
            s.append(".")
            i += 1
            guard isDigit(peek()) else { throw err("missing fraction digits") }
            while let c = peek(), isDigit(c) {
                s.append(c)
                i += 1
            }
        }
        if peek() == "e" || peek() == "E" {
            s.append("e")
            i += 1
            if let sign = peek(), sign == "+" || sign == "-" {
                s.append(sign)
                i += 1
            }
            guard isDigit(peek()) else { throw err("missing exponent digits") }
            while let c = peek(), isDigit(c) {
                s.append(c)
                i += 1
            }
        }
        guard let v = Double(s) else { throw err("invalid number") }
        return v
    }
}
