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
        let open = i
        // Shared string grammar (Core/Tokenizer.swift); the pull reader holds the whole input, so
        // `.incomplete` means truncated. Decode here once the extent + escape flag are known.
        let outcome = bytes.withUnsafeBufferPointer { buf -> JSONString.ScanOutcome in
            guard let p = buf.baseAddress else { return .incomplete }
            return JSONString.scanLexeme(p, open, n, strict: strict)
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
                return hasEscape
                    ? JSONString.unescape(p, start, length)
                    : String(decoding: UnsafeBufferPointer(start: p + start, count: length), as: UTF8.self)
            }
        }
    }

    private mutating func readNumber() throws(JSONError) -> Double {
        let start = i
        // Shared number grammar (Core/Tokenizer.swift). The pull reader holds the whole input, so
        // `complete: true` — the buffer end is final, never `.incomplete`.
        let outcome = bytes.withUnsafeBufferPointer { buf -> JSONNumber.ScanOutcome in
            guard let p = buf.baseAddress else { return .invalid }
            return JSONNumber.scanLexeme(p, start, n, strict: strict, complete: true)
        }
        guard case .ok(let end) = outcome else { throw JSONError.invalidNumber(at: start) }
        i = end
        return bytes.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return .nan }
            return JSONNumber.parseDouble(p, start, end - start)
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
/// `feed(_:)` — each call returns every ``JSONEvent`` that is now fully available — and call
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
        case .ok(let end, let hasEscape):
            var j = end
            while j < count, isWS(buffer[j]) { j += 1 }
            if j >= count { return .needMore }  // colon not here yet → retry the whole key+colon
            guard buffer[j] == 0x3A else { throw JSONError.unexpectedCharacter(buffer[j], at: j) }
            let key = decodeString(open, end, hasEscape: hasEscape)
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
            case .ok(let end, let hasEscape):
                let s = decodeString(i, end, hasEscape: hasEscape)
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

    // `.ok(end, hasEscape)`: `end` is the index past the close quote, `hasEscape` reports whether the
    // body contains a backslash (so `decodeString` skips a second scan). `.incomplete` if the buffer
    // ends mid-string.
    private enum StringScanOutcome { case ok(Int, Bool), incomplete }

    // Scan a `"…"` string from the opening quote `open` via the shared grammar (Core/Tokenizer.swift).
    // `.incomplete` (buffer ended mid-token) means "wait for the next feed"; `.invalid` is malformed.
    private func scanStringEnd(_ open: Int) throws(JSONError) -> StringScanOutcome {
        let outcome = buffer.withUnsafeBufferPointer { buf -> JSONString.ScanOutcome in
            guard let p = buf.baseAddress else { return .incomplete }
            return JSONString.scanLexeme(p, open, count, strict: strict)
        }
        switch outcome {
        case .ok(let end, let hasEscape): return .ok(end, hasEscape)
        case .incomplete: return .incomplete
        case .invalid: throw JSONError.invalidString(at: open)
        }
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
        // Shared grammar (Core/Tokenizer.swift). `complete: finished` makes a lexeme that runs to the
        // buffer end `.incomplete` mid-stream but final once `finish()` has been signalled.
        let outcome = buffer.withUnsafeBufferPointer { buf -> JSONNumber.ScanOutcome in
            guard let p = buf.baseAddress else { return .incomplete }
            return JSONNumber.scanLexeme(p, start, count, strict: strict, complete: finished)
        }
        switch outcome {
        case .ok(let end): return .ok(end)
        case .incomplete: return .incomplete
        case .invalid: throw JSONError.invalidNumber(at: start)
        }
    }

    // `hasEscape` is threaded from `scanStringEnd` (which already detected it), so the body is decoded
    // without a second scan for backslashes.
    private func decodeString(_ open: Int, _ endPastQuote: Int, hasEscape: Bool) -> String {
        let start = open + 1
        let length = endPastQuote - 1 - start
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
