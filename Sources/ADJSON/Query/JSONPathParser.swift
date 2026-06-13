import Foundation

struct JSONPathError: Error, Sendable {
    let message: String
    let position: Int
}

struct JSONPathParser {
    let chars: [Character]
    var i = 0

    init(_ s: String) { chars = Array(s) }

    var atEnd: Bool { i >= chars.count }
    func peek() -> Character? { i < chars.count ? chars[i] : nil }
    func peek2() -> Character? { i + 1 < chars.count ? chars[i + 1] : nil }
    func err(_ m: String) -> JSONPathError { JSONPathError(message: m, position: i) }

    mutating func skipWS() {
        while i < chars.count, chars[i] == " " || chars[i] == "\t" || chars[i] == "\n" || chars[i] == "\r" { i += 1 }
    }

    mutating func expect(_ c: Character) throws {
        skipWS()
        guard peek() == c else { throw err("expected '\(c)'") }
        i += 1
    }

    mutating func parseRoot() throws -> [PathSegment] {
        skipWS()
        guard peek() == "$" else { throw err("path must start with $") }
        i += 1
        let segs = try parseSegments()
        skipWS()
        guard atEnd else { throw err("unexpected trailing characters") }
        return segs
    }

    mutating func parseSegments() throws -> [PathSegment] {
        var segs: [PathSegment] = []
        loop: while let c = peek() {
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
                break loop
            }
        }
        return segs
    }

    mutating func parseAfterDescendant() throws -> [Selector] {
        guard let c = peek() else { throw err("expected selector after '..'") }
        if c == "[" { return try parseBracket() }
        if c == "*" {
            i += 1
            return [.wildcard]
        }
        return [.name(try parseMemberName())]
    }

    mutating func parseDotSelector() throws -> Selector {
        guard let c = peek() else { throw err("expected selector after '.'") }
        if c == "*" {
            i += 1
            return .wildcard
        }
        return .name(try parseMemberName())
    }

    mutating func parseMemberName() throws -> String {
        var name = ""
        while let c = peek(), c.isLetter || c.isNumber || c == "_" || (c.unicodeScalars.first?.value ?? 0) > 0x7F {
            name.append(c)
            i += 1
        }
        guard !name.isEmpty else { throw err("empty member name") }
        return name
    }

    mutating func parseBracket() throws -> [Selector] {
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

    mutating func parseBracketSelector() throws -> Selector {
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

    mutating func parseIndexOrSlice() throws -> Selector {
        let first = try? parseInt()
        skipWS()
        if peek() == ":" {
            i += 1
            skipWS()
            let end = try? parseInt()
            skipWS()
            var step = 1
            if peek() == ":" {
                i += 1
                skipWS()
                step = (try? parseInt()) ?? 1
            }
            return .slice(start: first, end: end, step: step)
        }
        guard let idx = first else { throw err("expected index or slice") }
        return .index(idx)
    }

    mutating func parseInt() throws -> Int {
        skipWS()
        var s = ""
        if peek() == "-" {
            s.append("-")
            i += 1
        }
        while let c = peek(), c.isNumber {
            s.append(c)
            i += 1
        }
        guard let v = Int(s) else { throw err("invalid integer") }
        return v
    }

    mutating func parseQuotedString() throws -> String {
        let quote = chars[i]
        i += 1
        var s = ""
        while let c = peek() {
            i += 1
            if c == "\\" {
                guard let e = peek() else { break }
                i += 1
                switch e {
                case "n": s.append("\n")
                case "t": s.append("\t")
                case "r": s.append("\r")
                case "\\": s.append("\\")
                case "/": s.append("/")
                case "'": s.append("'")
                case "\"": s.append("\"")
                case "u":
                    var hex = ""
                    for _ in 0..<4 where peek() != nil {
                        hex.append(chars[i])
                        i += 1
                    }
                    if let v = UInt32(hex, radix: 16), let us = Unicode.Scalar(v) { s.unicodeScalars.append(us) }
                default: s.append(e)
                }
            } else if c == quote {
                return s
            } else {
                s.append(c)
            }
        }
        throw err("unterminated string")
    }

    // MARK: - Filter expressions

    mutating func parseFilter() throws -> FilterExpr { try parseOr() }

    mutating func parseOr() throws -> FilterExpr {
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

    mutating func parseAnd() throws -> FilterExpr {
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

    mutating func parseNot() throws -> FilterExpr {
        skipWS()
        if peek() == "!" {
            i += 1
            return .not(try parseNot())
        }
        return try parsePrimary()
    }

    mutating func parsePrimary() throws -> FilterExpr {
        skipWS()
        if peek() == "(" {
            i += 1
            let e = try parseOr()
            try expect(")")
            return e
        }
        if let fn = peekIdentifier(), fn == "match" || fn == "search" {
            consumeIdentifier(fn)
            try expect("(")
            let a = try parseComparand()
            try expect(",")
            let b = try parseComparand()
            try expect(")")
            return .regex(a, pattern: b, anchored: fn == "match")
        }
        let left = try parseComparand()
        if let op = parseCompOp() {
            let right = try parseComparand()
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

    mutating func parseComparand() throws -> Comparand {
        skipWS()
        guard let c = peek() else { throw err("expected comparand") }
        if c == "@" || c == "$" { return .query(try parseRelQuery()) }
        if let fn = peekIdentifier(), fn == "length" || fn == "count" {
            consumeIdentifier(fn)
            try expect("(")
            let q = try parseRelQuery()
            try expect(")")
            return fn == "length" ? .length(q) : .count(q)
        }
        if c == "'" || c == "\"" { return .literal(.string(try parseQuotedString())) }
        if c == "-" || c.isNumber { return .literal(.number(try parseNumber())) }
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

    mutating func parseRelQuery() throws -> RelQuery {
        skipWS()
        guard peek() == "@" || peek() == "$" else { throw err("expected '@' or '$'") }
        let fromRoot = peek() == "$"
        i += 1
        let segs = try parseSegments()
        return RelQuery(fromRoot: fromRoot, segments: segs)
    }

    mutating func parseNumber() throws -> Double {
        skipWS()
        var s = ""
        if peek() == "-" {
            s.append("-")
            i += 1
        }
        while let c = peek(), c.isNumber || c == "." || c == "e" || c == "E" || c == "+" || c == "-" {
            s.append(c)
            i += 1
        }
        guard let v = Double(s) else { throw err("invalid number") }
        return v
    }
}
