// RFC 9535 filter-expression sub-language for `JSONPathParser` — the precedence-climbing recursive
// descent (`parseOr`→`parseAnd`→`parseNot`→`parsePrimary`→`parseComparand`), comparands, the
// match / search / length / count / value functions, comparison operators, and the filter-literal
// number parser. Split from JSONPathParser.swift to keep the core scanner type body within the
// size/complexity gate; behaviour is unchanged (the RFC 9535 compliance suite covers both halves).

extension JSONPathParser {
    // MARK: - Filter expressions

    // Design note: the filter grammar is a hand-written precedence-climbing recursive descent
    // (`parseOr` → `parseAnd` → `parseNot` → `parsePrimary` → `parseComparand`), NOT a Pratt parser /
    // PDA. A Pratt form would be cosmetic here: the only recursion is structural (parenthesised
    // sub-expressions and nested bracket-filters), already bounded by `enter()` / `maxDepth` (64) and
    // proven stack-safe — `&&`/`||` iterate and `!` folds by parity, so no unbounded recursion remains
    // to remove. A rewrite would risk a CTS regression for no safety or correctness gain.
    mutating func parseFilter() throws(JSONPathError) -> FilterExpr { try parseOr() }

    mutating func parseOr() throws(JSONPathError) -> FilterExpr {
        var terms = [try parseAnd()]
        while true {
            skipWS()
            guard peek() == 0x7C, peek2() == 0x7C else {
                break
            }
            i += 2
            terms.append(try parseAnd())
        }
        return terms.count == 1 ? terms[0] : .or(terms)
    }

    mutating func parseAnd() throws(JSONPathError) -> FilterExpr {
        var terms = [try parseNot()]
        while true {
            skipWS()
            guard peek() == 0x26, peek2() == 0x26 else {
                break
            }
            i += 2
            terms.append(try parseNot())
        }
        return terms.count == 1 ? terms[0] : .and(terms)
    }

    mutating func parseNot() throws(JSONPathError) -> FilterExpr {
        // Consume the whole run of leading `!` iteratively, tracking parity, so a crafted
        // `[?!!!…!@]` (200k `!`) can't recurse one frame per `!` and overflow the stack.
        // `!!x ≡ x`, so only an odd count negates — folding the whole run in O(1) stack.
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
        if case .query(let q) = left { return .existence(q) }
        throw err("expected comparison or existence test")
    }

    // A string-literal pattern is known now, so validate it against the I-Regexp safe subset and
    // compile it once here — closing the ReDoS hole before any JSON is seen and avoiding an O(N)
    // recompile per filtered node. A non-literal pattern (a query/function result) is untrusted
    // until evaluation, so it is deferred and re-checked per node there.
    mutating func compileRegexOperand(_ b: Comparand) throws(JSONPathError) -> RegexOperand {
        guard case .literal(.string(let pat)) = b else { return .dynamic(b) }
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
        return j > start ? String(decoding: bytes[start ..< j], as: UTF8.self) : nil
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
