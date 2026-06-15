/// A single SAX event produced by ``JSONEventReader``.
///
/// `.number` carries the parsed `Double`, so an integer-shaped token beyond 2^53 loses precision.
/// When you need lossless 64-bit integers, materialize through ``JSONValue`` (which keeps an exact
/// `Int64`) or use the Codable decoder rather than the SAX stream — the reader exposes no separate
/// integer accessor. Object members surface as a `.key` event immediately followed by the value's
/// event(s).
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

    public init(_ bytes: [UInt8], options: JSONParseOptions = .strict) {
        self.bytes = bytes
        self.n = bytes.count
        self.strict = options.isStrict
        self.maxDepth = options.maxDepth
    }

    public init(_ string: String, options: JSONParseOptions = .strict) {
        self.init(Array(string.utf8), options: options)
    }

    /// The next event, or `nil` at the clean end of the document. Throws ``JSONError`` on malformed
    /// input. After `nil` is returned, further calls keep returning `nil`.
    public mutating func next() throws(JSONError) -> JSONEvent? {
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
        case 0x2D, 0x30...0x39:  // '-' / digit
            let value = try readNumber()
            expect = afterScalar
            return .number(value)
        default:
            throw JSONError.unexpectedCharacter(c, at: i)
        }
    }

    // Object member key: a string, then a mandatory `:`. Advances `expect` to read the value next.
    private mutating func readKeyEvent() throws(JSONError) -> JSONEvent {
        skipWS()
        guard i < n, bytes[i] == 0x22 else { throw JSONError.unexpectedCharacter(i < n ? bytes[i] : 0, at: i) }
        let key = try readString()
        skipWS()
        guard i < n, bytes[i] == 0x3A else { throw JSONError.unexpectedCharacter(i < n ? bytes[i] : 0, at: i) }
        i += 1  // ':'
        expect = .objectValue
        return .key(key)
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
        while i < n {
            let c = bytes[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 } else { break }
        }
    }

    // MARK: - Scalar tokenizers (one borrow per token; control flow above uses index access)

    private mutating func readString() throws(JSONError) -> String {
        var cursor = i
        let count = n
        let isStrict = strict
        let result: Result<String, JSONError> = bytes.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return .failure(.unexpectedEndOfInput) }
            return Result { () throws(JSONError) in
                let value = try Self.scanString(p, &cursor, count, strict: isStrict)
                return value
            }
        }
        i = cursor
        return try result.get()
    }

    // Scan + decode a `"…"` string starting at `i` (the opening quote); advances `i` past the close.
    private static func scanString(
        _ p: UnsafePointer<UInt8>, _ i: inout Int, _ n: Int, strict: Bool
    ) throws(JSONError) -> String {
        let start = i + 1
        var j = start
        var esc = false
        while j < n {
            let c = p[j]
            if c == 0x22 { break }
            if c == 0x5C {
                esc = true
                if strict {
                    try validateEscape(p, &j, n)
                } else {
                    j += 2
                }
                continue
            }
            if c < 0x20 { throw JSONError.invalidString(at: j) }
            if strict && c >= 0x80 {
                j += try JSONUTF8.sequenceLength(p, j, n)
                continue
            }
            j += 1
        }
        guard j < n else { throw JSONError.unexpectedEndOfInput }
        let length = j - start
        let decoded =
            esc
            ? JSONString.unescape(p, start, length)
            : String(decoding: UnsafeBufferPointer(start: p + start, count: length), as: UTF8.self)
        i = j + 1
        return decoded
    }

    // `p[j]` is a backslash; validate the strict-JSON escape and advance `j` past it.
    private static func validateEscape(_ p: UnsafePointer<UInt8>, _ j: inout Int, _ n: Int) throws(JSONError) {
        guard j + 1 < n else { throw JSONError.invalidString(at: j) }
        switch p[j + 1] {
        case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
            j += 2
        case 0x75:  // \uXXXX (with surrogate pairing)
            let high = try hex4(p, j + 2, n)
            if high >= 0xD800 && high <= 0xDBFF {
                guard j + 7 < n, p[j + 6] == 0x5C, p[j + 7] == 0x75 else { throw JSONError.invalidString(at: j) }
                let low = try hex4(p, j + 8, n)
                guard low >= 0xDC00 && low <= 0xDFFF else { throw JSONError.invalidString(at: j) }
                j += 12
            } else if high >= 0xDC00 && high <= 0xDFFF {
                throw JSONError.invalidString(at: j)
            } else {
                j += 6
            }
        default:
            throw JSONError.invalidString(at: j)
        }
    }

    private static func hex4(_ p: UnsafePointer<UInt8>, _ at: Int, _ n: Int) throws(JSONError) -> UInt16 {
        guard at + 4 <= n else { throw JSONError.invalidString(at: at) }
        var value: UInt16 = 0
        for k in 0..<4 {
            let b = p[at + k]
            let digit: UInt16
            switch b {
            case 0x30...0x39: digit = UInt16(b - 0x30)
            case 0x61...0x66: digit = UInt16(b - 0x61 + 10)
            case 0x41...0x46: digit = UInt16(b - 0x41 + 10)
            default: throw JSONError.invalidString(at: at)
            }
            value = (value << 4) | digit
        }
        return value
    }

    private mutating func readNumber() throws(JSONError) -> Double {
        let start = i
        // Find the token extent with the same grammar as the tape scanner.
        if strict {
            try scanNumberStrict()
        } else {
            try scanNumberLenient()
        }
        let length = i - start
        let begin = start
        return bytes.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return .nan }
            return JSONNumber.parseDouble(p, begin, length)
        }
    }

    private mutating func scanNumberStrict() throws(JSONError) {
        let start = i
        if i < n, bytes[i] == 0x2D { i += 1 }
        guard i < n else { throw JSONError.invalidNumber(at: start) }
        if bytes[i] == 0x30 {
            i += 1
            if i < n, isDigit(bytes[i]) { throw JSONError.invalidNumber(at: start) }  // no leading zero
        } else if bytes[i] >= 0x31 && bytes[i] <= 0x39 {
            i += 1
            while i < n, isDigit(bytes[i]) { i += 1 }
        } else {
            throw JSONError.invalidNumber(at: start)
        }
        if i < n, bytes[i] == 0x2E {
            i += 1
            guard i < n, isDigit(bytes[i]) else { throw JSONError.invalidNumber(at: start) }
            while i < n, isDigit(bytes[i]) { i += 1 }
        }
        if i < n, bytes[i] == 0x65 || bytes[i] == 0x45 {
            i += 1
            if i < n, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            guard i < n, isDigit(bytes[i]) else { throw JSONError.invalidNumber(at: start) }
            while i < n, isDigit(bytes[i]) { i += 1 }
        }
    }

    private mutating func scanNumberLenient() throws(JSONError) {
        let start = i
        if i < n, bytes[i] == 0x2D || bytes[i] == 0x2B { i += 1 }
        let intStart = i
        while i < n, isDigit(bytes[i]) { i += 1 }
        var sawDigits = i > intStart
        if i < n, bytes[i] == 0x2E {
            i += 1
            let fracStart = i
            while i < n, isDigit(bytes[i]) { i += 1 }
            sawDigits = sawDigits || i > fracStart
        }
        guard sawDigits else { throw JSONError.invalidNumber(at: start) }
        if i < n, bytes[i] == 0x65 || bytes[i] == 0x45 {
            i += 1
            if i < n, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            let expStart = i
            while i < n, isDigit(bytes[i]) { i += 1 }
            guard i > expStart else { throw JSONError.invalidNumber(at: start) }
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
            for k in 0..<length where bytes[start + k] != lit[k] { matched = false }
        }
        guard matched else { throw JSONError.unexpectedCharacter(bytes[i], at: i) }
        i += length
    }

    @inline(__always) private func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
}

/// A push-based (incremental / chunked) JSON event reader. Feed UTF-8 bytes as they arrive with
/// ``feed(_:)`` — each call returns every ``JSONEvent`` that is now fully available — and call
/// ``finish()`` once the stream ends. The reader suspends mid-token at any chunk boundary (a string,
/// number, escape, or multi-byte UTF-8 sequence split across feeds is resumed transparently) and
/// tracks nesting on a heap stack, so depth is bounded by ``JSONParseOptions/maxDepth`` and never by
/// the call stack. Consumed bytes are dropped after each drain, so memory stays proportional to the
/// largest single in-flight token, not the whole stream.
public struct JSONEventStreamReader {
    private var buffer: [UInt8] = []
    private var i = 0
    private var stack: [Bool] = []  // innermost container last (true = object)
    private var finished = false
    private let strict: Bool
    private let maxDepth: Int

    private enum Expect {
        case rootValue, rootDone
        case objectStart, objectKey, objectValue, objectCommaOrClose
        case arrayStart, arrayValue, arrayCommaOrClose
    }
    private var expect: Expect = .rootValue

    public init(options: JSONParseOptions = .strict) {
        self.strict = options.isStrict
        self.maxDepth = options.maxDepth
    }

    /// Append more input and return every event that is now complete. Partial trailing tokens are
    /// retained for the next ``feed(_:)`` / ``finish()``.
    public mutating func feed(_ bytes: [UInt8]) throws(JSONError) -> [JSONEvent] {
        buffer.append(contentsOf: bytes)
        return try drain()
    }

    /// Same as ``feed(_:)`` for a `String` chunk.
    public mutating func feed(_ string: String) throws(JSONError) -> [JSONEvent] {
        try feed(Array(string.utf8))
    }

    /// Signal end of input: drains any final events (numbers / literals at the very end are now
    /// known complete) and verifies the document closed cleanly. Throws on a truncated document.
    public mutating func finish() throws(JSONError) -> [JSONEvent] {
        finished = true
        let events = try drain()
        guard case .rootDone = expect else { throw JSONError.unexpectedEndOfInput }
        return events
    }

    private enum Step { case event(JSONEvent), progress, needMore, end }

    private mutating func drain() throws(JSONError) -> [JSONEvent] {
        var out: [JSONEvent] = []
        loop: while true {
            switch try step() {
            case .event(let event): out.append(event)
            case .progress: continue
            case .needMore, .end: break loop
            }
        }
        if i > 0 {  // drop consumed bytes so memory tracks the largest in-flight token, not the stream
            buffer.removeFirst(i)
            i = 0
        }
        return out
    }

    private var count: Int { buffer.count }

    private mutating func step() throws(JSONError) -> Step {
        switch expect {
        case .rootDone:
            skipWS()
            if i < count { throw JSONError.trailingData(at: i) }
            return .end
        case .rootValue:
            return try readValue(afterScalar: .rootDone)
        case .objectStart:
            skipWS()
            if i >= count { return .needMore }
            if buffer[i] == 0x7D {
                i += 1
                return .event(close())
            }
            return try readKey()
        case .objectKey:
            return try readKey()
        case .objectValue:
            return try readValue(afterScalar: .objectCommaOrClose)
        case .objectCommaOrClose:
            skipWS()
            if i >= count { return .needMore }
            if buffer[i] == 0x7D {
                i += 1
                return .event(close())
            }
            guard buffer[i] == 0x2C else { throw JSONError.unexpectedCharacter(buffer[i], at: i) }
            i += 1
            expect = .objectKey
            return .progress
        case .arrayStart:
            skipWS()
            if i >= count { return .needMore }
            if buffer[i] == 0x5D {
                i += 1
                return .event(close())
            }
            return try readValue(afterScalar: .arrayCommaOrClose)
        case .arrayValue:
            return try readValue(afterScalar: .arrayCommaOrClose)
        case .arrayCommaOrClose:
            skipWS()
            if i >= count { return .needMore }
            if buffer[i] == 0x5D {
                i += 1
                return .event(close())
            }
            guard buffer[i] == 0x2C else { throw JSONError.unexpectedCharacter(buffer[i], at: i) }
            i += 1
            expect = .arrayValue
            return .progress
        }
    }

    private mutating func close() -> JSONEvent {
        let wasObject = stack.removeLast()
        expect = stack.isEmpty ? .rootDone : (stack[stack.count - 1] ? .objectCommaOrClose : .arrayCommaOrClose)
        return wasObject ? .endObject : .endArray
    }

    // Read an object member key + its `:`. Commits `i` only once the whole `"key":` is present.
    private mutating func readKey() throws(JSONError) -> Step {
        skipWS()
        if i >= count { return .needMore }
        guard buffer[i] == 0x22 else { throw JSONError.unexpectedCharacter(buffer[i], at: i) }
        let open = i
        switch try scanStringEnd(open) {
        case .incomplete:
            return .needMore
        case .ok(let end):
            var j = end
            while j < count, isWS(buffer[j]) { j += 1 }
            if j >= count { return .needMore }  // colon not here yet → retry the whole key+colon
            guard buffer[j] == 0x3A else { throw JSONError.unexpectedCharacter(buffer[j], at: j) }
            let key = decodeString(open, end)
            i = j + 1
            expect = .objectValue
            return .event(.key(key))
        }
    }

    private mutating func readValue(afterScalar: Expect) throws(JSONError) -> Step {
        skipWS()
        if i >= count { return .needMore }
        let c = buffer[i]
        switch c {
        case 0x7B:  // '{'
            guard stack.count < maxDepth else { throw JSONError.depthExceeded(at: i) }
            i += 1
            stack.append(true)
            expect = .objectStart
            return .event(.beginObject)
        case 0x5B:  // '['
            guard stack.count < maxDepth else { throw JSONError.depthExceeded(at: i) }
            i += 1
            stack.append(false)
            expect = .arrayStart
            return .event(.beginArray)
        case 0x22:  // '"'
            switch try scanStringEnd(i) {
            case .incomplete: return .needMore
            case .ok(let end):
                let s = decodeString(i, end)
                i = end
                expect = afterScalar
                return .event(.string(s))
            }
        case 0x74, 0x66, 0x6E:  // t / f / n
            switch try scanLiteralEnd(i) {
            case .incomplete: return .needMore
            case .ok(let end, let event):
                i = end
                expect = afterScalar
                return .event(event)
            }
        case 0x2D, 0x30...0x39:  // '-' / digit
            switch try scanNumberEnd(i) {
            case .incomplete: return .needMore
            case .ok(let end):
                let value = parseNumber(i, end)
                i = end
                expect = afterScalar
                return .event(.number(value))
            }
        default:
            throw JSONError.unexpectedCharacter(c, at: i)
        }
    }

    // MARK: - Resumable scanners (index-based over `buffer`; `.incomplete` means "need more bytes")

    private enum ScanOutcome { case ok(Int), incomplete }

    // Scan a `"…"` string from the opening quote `open`. `.ok(end)` is the index past the close;
    // `.incomplete` if the buffer ends mid-string / mid-escape / mid-sequence. Throws on malformed.
    private func scanStringEnd(_ open: Int) throws(JSONError) -> ScanOutcome {
        var j = open + 1
        while true {
            guard j < count else { return .incomplete }
            let c = buffer[j]
            if c == 0x22 { return .ok(j + 1) }
            if c == 0x5C {  // escape
                guard j + 1 < count else { return .incomplete }
                if strict {
                    switch buffer[j + 1] {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: j += 2
                    case 0x75:  // \uXXXX, possibly a surrogate pair
                        guard j + 6 <= count else { return .incomplete }
                        let high = try hex4Indexed(j + 2)
                        if high >= 0xD800 && high <= 0xDBFF {
                            guard j + 12 <= count else { return .incomplete }
                            guard buffer[j + 6] == 0x5C, buffer[j + 7] == 0x75 else {
                                throw JSONError.invalidString(at: j)
                            }
                            let low = try hex4Indexed(j + 8)
                            guard low >= 0xDC00 && low <= 0xDFFF else { throw JSONError.invalidString(at: j) }
                            j += 12
                        } else if high >= 0xDC00 && high <= 0xDFFF {
                            throw JSONError.invalidString(at: j)
                        } else {
                            j += 6
                        }
                    default: throw JSONError.invalidString(at: j)
                    }
                } else {
                    j += 2
                }
                continue
            }
            if c < 0x20 { throw JSONError.invalidString(at: j) }
            if strict && c >= 0x80 {
                let length = try leadLength(c, at: j)
                guard j + length <= count else { return .incomplete }
                _ = try buffer.withUnsafeBufferPointer { buf throws(JSONError) -> Int in
                    // Reached only with a byte at `j` (c >= 0x80), so the buffer is non-empty and
                    // `baseAddress` is non-nil.
                    try JSONUTF8.sequenceLength(buf.baseAddress!, j, count)  // lint:allow
                }
                j += length
                continue
            }
            j += 1
        }
    }

    // Four hex digits at `at` (caller guaranteed in-bounds); throws on a non-hex digit.
    private func hex4Indexed(_ at: Int) throws(JSONError) -> UInt16 {
        var value: UInt16 = 0
        for k in 0..<4 {
            let b = buffer[at + k]
            let digit: UInt16
            switch b {
            case 0x30...0x39: digit = UInt16(b - 0x30)
            case 0x61...0x66: digit = UInt16(b - 0x61 + 10)
            case 0x41...0x46: digit = UInt16(b - 0x41 + 10)
            default: throw JSONError.invalidString(at: at)
            }
            value = (value << 4) | digit
        }
        return value
    }

    // UTF-8 lead-byte length (2–4); throws on an invalid lead. Bounds are checked by the caller.
    private func leadLength(_ b: UInt8, at j: Int) throws(JSONError) -> Int {
        if b & 0xE0 == 0xC0 { return 2 }
        if b & 0xF0 == 0xE0 { return 3 }
        if b & 0xF8 == 0xF0 { return 4 }
        throw JSONError.invalidUTF8(at: j)
    }

    // A literal (`true` / `false` / `null`). `.incomplete` if only a matching prefix is present and
    // the stream may still continue; throws on a mismatch or a truncated literal at end of input.
    private func scanLiteralEnd(_ start: Int) throws(JSONError) -> LiteralOutcome {
        let event: JSONEvent
        let literal: StaticString
        switch buffer[start] {
        case 0x74: (literal, event) = ("true", .bool(true))
        case 0x66: (literal, event) = ("false", .bool(false))
        default: (literal, event) = ("null", .null)
        }
        let length = literal.utf8CodeUnitCount
        let available = Swift.min(length, count - start)
        var matched = true
        literal.withUTF8Buffer { lit in
            for k in 0..<available where buffer[start + k] != lit[k] { matched = false }
        }
        guard matched else { throw JSONError.unexpectedCharacter(buffer[start], at: start) }
        if start + length > count {
            if finished { throw JSONError.unexpectedEndOfInput }  // truncated literal, no more coming
            return .incomplete
        }
        return .ok(start + length, event)
    }
    private enum LiteralOutcome { case ok(Int, JSONEvent), incomplete }

    // Loosely consume the number alphabet, then validate. Mid-stream a number that runs to the
    // buffer end is `.incomplete` (digits could continue); at `finish()` it is validated as-is.
    private func scanNumberEnd(_ start: Int) throws(JSONError) -> ScanOutcome {
        var j = start
        while j < count {
            let b = buffer[j]
            if isDigit(b) || b == 0x2D || b == 0x2B || b == 0x2E || b == 0x65 || b == 0x45 {
                j += 1
            } else {
                break
            }
        }
        if j >= count && !finished { return .incomplete }
        try validateNumber(start, j)
        return .ok(j)
    }

    // Validate `[start, end)` against the strict (or lenient) number grammar.
    private func validateNumber(_ start: Int, _ end: Int) throws(JSONError) {
        var k = start
        func digit() -> Bool { k < end && isDigit(buffer[k]) }
        if k < end, buffer[k] == 0x2D || (!strict && buffer[k] == 0x2B) { k += 1 }
        guard k < end else { throw JSONError.invalidNumber(at: start) }
        if strict {
            if buffer[k] == 0x30 {
                k += 1
                if digit() { throw JSONError.invalidNumber(at: start) }  // no leading zero
            } else if buffer[k] >= 0x31 && buffer[k] <= 0x39 {
                k += 1
                while digit() { k += 1 }
            } else {
                throw JSONError.invalidNumber(at: start)
            }
            if k < end, buffer[k] == 0x2E {
                k += 1
                guard digit() else { throw JSONError.invalidNumber(at: start) }
                while digit() { k += 1 }
            }
        } else {
            var sawDigits = false
            while digit() {
                k += 1
                sawDigits = true
            }
            if k < end, buffer[k] == 0x2E {
                k += 1
                while digit() {
                    k += 1
                    sawDigits = true
                }
            }
            guard sawDigits else { throw JSONError.invalidNumber(at: start) }
        }
        if k < end, buffer[k] == 0x65 || buffer[k] == 0x45 {
            k += 1
            if k < end, buffer[k] == 0x2B || buffer[k] == 0x2D { k += 1 }
            guard digit() else { throw JSONError.invalidNumber(at: start) }
            while digit() { k += 1 }
        }
        guard k == end else { throw JSONError.invalidNumber(at: start) }
    }

    private func decodeString(_ open: Int, _ endPastQuote: Int) -> String {
        let start = open + 1
        let length = endPastQuote - 1 - start
        var hasEscape = false
        for k in start..<(start + length) where buffer[k] == 0x5C {
            hasEscape = true
            break
        }
        return buffer.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return "" }
            if !hasEscape {
                return String(decoding: UnsafeBufferPointer(start: p + start, count: length), as: UTF8.self)
            }
            return JSONString.unescape(p, start, length)
        }
    }

    private func parseNumber(_ start: Int, _ end: Int) -> Double {
        buffer.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return .nan }
            return JSONNumber.parseDouble(p, start, end - start)
        }
    }

    @inline(__always) private mutating func skipWS() {
        while i < count {
            let c = buffer[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 } else { break }
        }
    }

    @inline(__always) private func isWS(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }
    @inline(__always) private func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
}
