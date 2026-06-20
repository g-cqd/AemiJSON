/// A single SAX event produced by ``JSONEventReader``.
///
/// `.number` carries the parsed `Double`, so an integer-shaped token beyond 2^53, or a high-precision
/// decimal, loses precision in the payload. To recover the exact value from the pull reader, read
/// ``JSONEventReader/currentNumberLexeme`` right after a `.number` event (the raw source digits, from
/// which an exact `Int64`/`Decimal` parses); alternatively materialize through ``JSONValue`` or use the
/// Codable decoder. Object members surface as a `.key` event immediately followed by the value's event(s).
public enum JSONEvent: Sendable, Equatable {
    case beginObject
    case endObject
    case beginArray
    case endArray
    case key(String)
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

/// A pull-based (SAX) reader over a *complete* UTF-8 JSON buffer: call ``next()`` repeatedly to draw
/// the document's structure as a flat stream of ``JSONEvent``s, without building a tape or a tree.
/// Useful for very large documents you can process incrementally and discard.
///
/// Depth is tracked on an explicit heap stack, so arbitrarily deep input is handled iteratively and
/// can never overflow the call stack (bounded by ``JSONParseOptions/maxDepth``). The same RFC 8259
/// tokenization as the tape parser is used — string escapes and UTF-8 are validated in strict mode;
/// numbers are parsed locale-independently. The reader owns its bytes and is a value type.
public struct JSONEventReader {
    private let bytes: [UInt8]
    private let n: Int
    private let strict: Bool
    private let isJSON5: Bool
    private let maxDepth: Int
    private var i = 0

    // The open containers, innermost last (`true` = object). Replaces recursion with heap depth.
    private var stack: [Bool] = []
    // What the next `next()` must read. A compact state machine over the RFC 8259 grammar.
    private enum Expect {
        case rootValue, rootDone
        case objectKeyOrClose, objectValue, objectCommaOrClose
        case arrayValueOrClose, arrayCommaOrClose
    }
    private var expect: Expect = .rootValue
    // Byte range of the number behind the most recent `.number` event, for `currentNumberLexeme`.
    // Set by `readNumber`; cleared at the top of each `next()` so it reflects only the last event.
    private var lastNumberRange: Range<Int>?

    public init(_ bytes: [UInt8], options: JSONParseOptions = .strict) {
        self.bytes = bytes
        self.n = bytes.count
        self.strict = options.isStrict
        self.isJSON5 = options.isJSON5
        self.maxDepth = options.maxDepth
    }

    public init(_ string: String, options: JSONParseOptions = .strict) {
        self.init(Array(string.utf8), options: options)
    }

    /// The next event, or `nil` at the clean end of the document. Throws ``JSONError`` on malformed
    /// input. After `nil` is returned, further calls keep returning `nil`.
    public mutating func next() throws(JSONError) -> JSONEvent? {
        lastNumberRange = nil  // a non-number event leaves `currentNumberLexeme` nil
        switch expect {
            case .rootDone:
                skipWS()
                guard i >= n else { throw JSONError.trailingData(at: i) }
                return nil
            case .rootValue:
                return try emitValue(afterScalar: .rootDone)
            case .objectKeyOrClose:
                skipWS()
                guard i < n else { throw JSONError.unexpectedEndOfInput }
                if bytes[i] == 0x7D {  // '}'
                    i += 1
                    return closeContainer()
                }
                return try readKeyEvent()
            case .objectValue:
                return try emitValue(afterScalar: .objectCommaOrClose)
            case .objectCommaOrClose:
                skipWS()
                guard i < n else { throw JSONError.unexpectedEndOfInput }
                if bytes[i] == 0x7D {  // '}'
                    i += 1
                    return closeContainer()
                }
                guard bytes[i] == 0x2C else { throw JSONError.unexpectedCharacter(bytes[i], at: i) }  // ','
                i += 1
                if isJSON5 {  // JSON5 trailing comma: `,` directly before `}` closes the object
                    skipWS()
                    if i < n, bytes[i] == 0x7D {
                        i += 1
                        return closeContainer()
                    }
                }
                return try readKeyEvent()
            case .arrayValueOrClose:
                skipWS()
                guard i < n else { throw JSONError.unexpectedEndOfInput }
                if bytes[i] == 0x5D {  // ']'
                    i += 1
                    return closeContainer()
                }
                return try emitValue(afterScalar: .arrayCommaOrClose)
            case .arrayCommaOrClose:
                skipWS()
                guard i < n else { throw JSONError.unexpectedEndOfInput }
                if bytes[i] == 0x5D {  // ']'
                    i += 1
                    return closeContainer()
                }
                guard bytes[i] == 0x2C else { throw JSONError.unexpectedCharacter(bytes[i], at: i) }  // ','
                i += 1
                if isJSON5 {  // JSON5 trailing comma: `,` directly before `]` closes the array
                    skipWS()
                    if i < n, bytes[i] == 0x5D {
                        i += 1
                        return closeContainer()
                    }
                }
                return try emitValue(afterScalar: .arrayCommaOrClose)
        }
    }

    // Read a value at the cursor: a container opens (push + begin event), a scalar is emitted with
    // `expect` advanced to `afterScalar`.
    private mutating func emitValue(afterScalar: Expect) throws(JSONError) -> JSONEvent {
        skipWS()
        guard i < n else { throw JSONError.unexpectedEndOfInput }
        let c = bytes[i]
        switch c {
            case 0x7B:  // '{'
                guard stack.count < maxDepth else { throw JSONError.depthExceeded(at: i) }
                i += 1
                stack.append(true)
                expect = .objectKeyOrClose
                return .beginObject
            case 0x5B:  // '['
                guard stack.count < maxDepth else { throw JSONError.depthExceeded(at: i) }
                i += 1
                stack.append(false)
                expect = .arrayValueOrClose
                return .beginArray
            case 0x22:  // '"'
                let s = try readString()
                expect = afterScalar
                return .string(s)
            case 0x74, 0x66, 0x6E:  // t / f / n
                let event = try readLiteral()
                expect = afterScalar
                return event
            case 0x2D, 0x30 ... 0x39:  // '-' / digit
                let value = try readNumber()
                expect = afterScalar
                return .number(value)
            default:
                // JSON5 value starts: single-quoted string, leading `+`/`.`, and `Infinity` / `NaN`.
                if isJSON5, c == 0x27 {
                    let s = try readString()
                    expect = afterScalar
                    return .string(s)
                }
                if isJSON5, c == 0x2B || c == 0x2E || c == 0x49 || c == 0x4E {  // + . I(nfinity) N(aN)
                    let value = try readNumber()
                    expect = afterScalar
                    return .number(value)
                }
                throw JSONError.unexpectedCharacter(c, at: i)
        }
    }

    // Object member key: a string (JSON5: also single-quoted or an unquoted identifier), then a
    // mandatory `:`. Advances `expect` to read the value next.
    private mutating func readKeyEvent() throws(JSONError) -> JSONEvent {
        skipWS()
        let key: String
        if isJSON5, i < n, bytes[i] != 0x22, bytes[i] != 0x27 {
            key = try readIdentifierKey()  // unquoted ECMAScript identifier
        } else {
            guard i < n, bytes[i] == 0x22 || (isJSON5 && bytes[i] == 0x27) else {
                throw JSONError.unexpectedCharacter(i < n ? bytes[i] : 0, at: i)
            }
            key = try readString()
        }
        skipWS()
        guard i < n, bytes[i] == 0x3A else { throw JSONError.unexpectedCharacter(i < n ? bytes[i] : 0, at: i) }
        i += 1  // ':'
        expect = .objectValue
        return .key(key)
    }

    private mutating func readIdentifierKey() throws(JSONError) -> String {
        let start = i
        let outcome = bytes.withUnsafeBufferPointer { buf -> JSONString.ScanOutcome in
            guard let p = buf.baseAddress else { return .invalid }
            return JSONString.scanIdentifier(p, start, n, complete: true)
        }
        guard case .ok(let end, _) = outcome else {
            throw JSONError.unexpectedCharacter(i < n ? bytes[i] : 0, at: i)
        }
        i = end
        return bytes.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return "" }
            return String(decoding: UnsafeBufferPointer(start: p + start, count: end - start), as: UTF8.self)
        }
    }

    // Pop the just-closed container and set `expect` from the new innermost context.
    private mutating func closeContainer() -> JSONEvent {
        let wasObject = stack.removeLast()
        if stack.isEmpty {
            expect = .rootDone
        } else {
            expect = stack[stack.count - 1] ? .objectCommaOrClose : .arrayCommaOrClose
        }
        return wasObject ? .endObject : .endArray
    }

    @inline(__always) private mutating func skipWS() {
        // The pull reader holds the whole input, so `complete: true`: a trailing JSON5 comment is
        // consumed rather than reported incomplete. Both plain and JSON5 skipping route through the
        // one shared `JSONToken.skipInsignificant` policy (the push reader uses it too).
        i = bytes.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return i }
            return JSONToken.skipInsignificant(p, i, n, json5: isJSON5, complete: true).end
        }
    }

    // MARK: - Scalar tokenizers (one borrow per token; control flow above uses index access)

    private mutating func readString() throws(JSONError) -> String {
        let open = i
        // Shared string grammar (Core/Tokenizer.swift); the pull reader holds the whole input, so
        // `.incomplete` means truncated. Decode here once the extent + escape flag are known.
        let outcome = bytes.withUnsafeBufferPointer { buf -> JSONString.ScanOutcome in
            guard let p = buf.baseAddress else { return .incomplete }
            return isJSON5 ? JSONString.scanJSON5Lexeme(p, open, n) : JSONString.scanLexeme(p, open, n, strict: strict)
        }
        switch outcome {
            case .incomplete:
                throw JSONError.unexpectedEndOfInput
            case .invalid:
                throw JSONError.invalidString(at: open)
            case .ok(let end, let hasEscape):
                let start = open + 1
                let length = end - 1 - start
                i = end
                return bytes.withUnsafeBufferPointer { buf in
                    guard let p = buf.baseAddress else { return "" }
                    if !hasEscape {
                        return String(decoding: UnsafeBufferPointer(start: p + start, count: length), as: UTF8.self)
                    }
                    return isJSON5 ? JSONString.unescapeJSON5(p, start, length) : JSONString.unescape(p, start, length)
                }
        }
    }

    private mutating func readNumber() throws(JSONError) -> Double {
        let start = i
        // Shared number grammar (Core/Tokenizer.swift). The pull reader holds the whole input, so
        // `complete: true` — the buffer end is final, never `.incomplete`.
        let outcome = bytes.withUnsafeBufferPointer { buf -> JSONNumber.ScanOutcome in
            guard let p = buf.baseAddress else { return .invalid }
            return isJSON5
                ? JSONNumber.scanJSON5Lexeme(p, start, n, complete: true)
                : JSONNumber.scanLexeme(p, start, n, strict: strict, complete: true)
        }
        guard case .ok(let end) = outcome else { throw JSONError.invalidNumber(at: start) }
        i = end
        lastNumberRange = start ..< end
        return bytes.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return .nan }
            return JSONNumber.parseDouble(p, start, end - start)
        }
    }

    /// The raw UTF-8 lexeme — the exact source digits — of the number behind the most recently
    /// returned `.number` event, or `nil` if the last event was not a number. Lets a consumer recover a
    /// value the `Double` payload would round: an integer beyond 2^53 (`Int64(lexeme)`) or a
    /// high-precision decimal. Valid until the next ``next()`` call. The bytes are ASCII (RFC 8259 /
    /// JSON5 numbers), so the decode never fails.
    public var currentNumberLexeme: String? {
        guard let range = lastNumberRange else { return nil }
        return bytes.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return nil }
            return String(decoding: UnsafeBufferPointer(start: p + range.lowerBound, count: range.count), as: UTF8.self)
        }
    }

    private mutating func readLiteral() throws(JSONError) -> JSONEvent {
        switch bytes[i] {
            case 0x74:
                try expectLiteral("true")
                return .bool(true)
            case 0x66:
                try expectLiteral("false")
                return .bool(false)
            default:
                try expectLiteral("null")
                return .null
        }
    }

    private mutating func expectLiteral(_ literal: StaticString) throws(JSONError) {
        let length = literal.utf8CodeUnitCount
        guard i + length <= n else { throw JSONError.unexpectedCharacter(i < n ? bytes[i] : 0, at: i) }
        let start = i
        var matched = true
        literal.withUTF8Buffer { lit in
            for k in 0 ..< length where bytes[start + k] != lit[k] { matched = false }
        }
        guard matched else { throw JSONError.unexpectedCharacter(bytes[i], at: i) }
        i += length
    }
}
