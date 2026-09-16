/// A push-based (incremental / chunked) JSON event reader. Feed UTF-8 bytes as they arrive with
/// `feed(_:)` — each call returns every ``JSONEvent`` that is now fully available — and call
/// ``finish()`` once the stream ends. The reader suspends mid-token at any chunk boundary (a string,
/// number, escape, or multi-byte UTF-8 sequence split across feeds is resumed transparently) and
/// tracks nesting on a heap stack, so depth is bounded by ``JSONParseOptions/maxDepth`` and never by
/// the call stack. Consumed bytes are dropped after each drain, so memory stays proportional to the
/// largest single in-flight token, not the whole stream.
public struct JSONEventStreamReader {
    // The live window is `buffer[readOffset...]`. Draining consumes bytes by advancing `readOffset`
    // (an O(1) cursor bump) instead of shifting the tail left on every feed — a steadily-fed stream is
    // O(n) overall rather than O(n²). All scanner offsets (`i`, `j`, `start`, `open`, …) and `count`
    // are *window-relative*: index 0 is the byte at physical `readOffset`, so error `at:` positions and
    // the emitted event sequence are byte-for-byte identical to the previous compact-every-feed reader.
    private var buffer: [UInt8] = []
    private var readOffset = 0
    private var i = 0
    private var stack: [Bool] = []  // innermost container last (true = object)
    private var finished = false
    private let strict: Bool
    private let isJSON5: Bool
    private let maxDepth: Int

    // Drop the consumed prefix once it dominates the buffer, so physical storage stays bounded by the
    // unconsumed tail (the header guarantee) without copying after every small feed. The amortized cost
    // of compaction is O(1) per consumed byte: each byte is shifted at most once before `readOffset`
    // halves the buffer. 4 KiB floor keeps tiny incremental feeds from churning on a sub-page move.
    private static let compactionFloor = 4096

    private enum Expect {
        case rootValue, rootDone
        case objectStart, objectKey, objectValue, objectCommaOrClose
        case arrayStart, arrayValue, arrayCommaOrClose
    }
    private var expect: Expect = .rootValue

    public init(options: JSONParseOptions = .strict) {
        self.strict = options.isStrict
        self.isJSON5 = options.isJSON5
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

    private enum Step {
        case event(JSONEvent)
        case progress, needMore, end
    }

    private mutating func drain() throws(JSONError) -> [JSONEvent] {
        var out: [JSONEvent] = []
        loop: while true {
            switch try step() {
                case .event(let event): out.append(event)
                case .progress: continue
                case .needMore, .end: break loop
            }
        }
        // Consume the drained bytes by advancing the window cursor (O(1)); only physically drop the
        // dead prefix once it grows past half the buffer (and a small floor), so memory still tracks
        // the unconsumed tail but a steadily-fed stream pays O(n), not O(n²), in total drain cost.
        if i > 0 {
            readOffset += i
            i = 0
            if readOffset >= Self.compactionFloor, readOffset > buffer.count - readOffset {
                buffer.removeFirst(readOffset)
                readOffset = 0
            }
        }
        return out
    }

    // Window length: the number of unconsumed bytes, i.e. valid window-relative indices are `[0, count)`.
    private var count: Int { buffer.count - readOffset }

    // The byte at a window-relative index. Callers guard `idx < count`, so `readOffset + idx` stays in
    // `[readOffset, buffer.count)` — the unconsumed window — and the array's own bounds check still
    // backstops it. Compiles to the same access as the former `buffer[idx]` once `readOffset` is 0.
    @inline(__always) private func byte(_ idx: Int) -> UInt8 { buffer[readOffset + idx] }

    private mutating func step() throws(JSONError) -> Step {
        switch expect {
            case .rootDone:
                if skipWS() { return .needMore }
                if i < count { throw JSONError.trailingData(at: i) }
                return .end
            case .rootValue:
                return try readValue(afterScalar: .rootDone)
            case .objectStart:
                if skipWS() { return .needMore }
                if i >= count { return .needMore }
                if byte(i) == 0x7D {
                    i += 1
                    return .event(close())
                }
                return try readKey()
            case .objectKey:
                return try readKey()
            case .objectValue:
                return try readValue(afterScalar: .objectCommaOrClose)
            case .objectCommaOrClose:
                return try commaOrClose(0x7D, json5Restart: .objectStart, plainNext: .objectKey)
            case .arrayStart:
                if skipWS() { return .needMore }
                if i >= count { return .needMore }
                if byte(i) == 0x5D {
                    i += 1
                    return .event(close())
                }
                return try readValue(afterScalar: .arrayCommaOrClose)
            case .arrayValue:
                return try readValue(afterScalar: .arrayCommaOrClose)
            case .arrayCommaOrClose:
                return try commaOrClose(0x5D, json5Restart: .arrayStart, plainNext: .arrayValue)
        }
    }

    // Shared `,`-or-close handling for the object/array `…CommaOrClose` states: close on `closer`,
    // else require a `,` and advance to `plainNext` (or `json5Restart` in JSON5, which also accepts a
    // trailing-comma close).
    private mutating func commaOrClose(
        _ closer: UInt8, json5Restart: Expect, plainNext: Expect
    ) throws(JSONError) -> Step {
        if skipWS() { return .needMore }
        if i >= count { return .needMore }
        if byte(i) == closer {
            i += 1
            return .event(close())
        }
        guard byte(i) == 0x2C else { throw JSONError.unexpectedCharacter(byte(i), at: i) }
        i += 1
        expect = isJSON5 ? json5Restart : plainNext
        return .progress
    }

    private mutating func close() -> JSONEvent {
        let wasObject = stack.removeLast()
        expect = stack.isEmpty ? .rootDone : (stack[stack.count - 1] ? .objectCommaOrClose : .arrayCommaOrClose)
        return wasObject ? .endObject : .endArray
    }

    // Read an object member key + its `:`. Commits `i` only once the whole `key :` is present, so a
    // key split across feeds is rescanned. JSON5 adds single-quoted and unquoted-identifier keys.
    private mutating func readKey() throws(JSONError) -> Step {
        if skipWS() { return .needMore }
        if i >= count { return .needMore }
        let open = i
        let c = byte(i)
        let keyEnd: Int
        let key: String
        let base = readOffset
        if isJSON5, c != 0x22, c != 0x27 {  // unquoted ECMAScript identifier
            let outcome = buffer.withUnsafeBufferPointer { buf -> JSONString.ScanOutcome in
                guard let p = unsafe buf.baseAddress.map({ unsafe $0 + base }) else { return .incomplete }
                return unsafe JSONString.scanIdentifier(p, open, count, complete: finished)
            }
            switch outcome {
                case .incomplete: return .needMore
                case .invalid: throw JSONError.unexpectedCharacter(c, at: i)
                case .ok(let end, _):
                    keyEnd = end
                    key = buffer.withUnsafeBufferPointer { buf in
                        guard let p = unsafe buf.baseAddress.map({ unsafe $0 + base }) else { return "" }
                        return unsafe String(
                            decoding: UnsafeBufferPointer(start: p + open, count: end - open), as: UTF8.self)
                    }
            }
        } else {
            guard c == 0x22 || (isJSON5 && c == 0x27) else { throw JSONError.unexpectedCharacter(c, at: i) }
            switch try scanStringEnd(open) {
                case .incomplete: return .needMore
                case .ok(let end, let hasEscape):
                    keyEnd = end
                    key = decodeString(open, end, hasEscape: hasEscape)
            }
        }
        // The mandatory `:` (JSON5 permits whitespace/comments between the key and the colon).
        let skip = buffer.withUnsafeBufferPointer { buf -> JSONToken.SkipResult in
            guard let p = unsafe buf.baseAddress.map({ unsafe $0 + base }) else {
                return JSONToken.SkipResult(end: keyEnd, incomplete: false)
            }
            return unsafe JSONToken.skipInsignificant(p, keyEnd, count, json5: isJSON5, complete: finished)
        }
        if skip.incomplete { return .needMore }
        let j = skip.end
        if j >= count { return .needMore }  // colon not here yet → retry the whole key + colon
        guard byte(j) == 0x3A else { throw JSONError.unexpectedCharacter(byte(j), at: j) }
        i = j + 1
        expect = .objectValue
        return .event(.key(key))
    }

    private mutating func readValue(afterScalar: Expect) throws(JSONError) -> Step {
        if skipWS() { return .needMore }
        if i >= count { return .needMore }
        let c = byte(i)
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
            case 0x2D, 0x30 ... 0x39:  // '-' / digit
                switch try scanNumberEnd(i) {
                    case .incomplete: return .needMore
                    case .ok(let end):
                        let value = parseNumber(i, end)
                        i = end
                        expect = afterScalar
                        return .event(.number(value))
                }
            default:
                // JSON5 value starts: single-quoted string and leading `+`/`.`/`Infinity`/`NaN`.
                if isJSON5, c == 0x27 {
                    switch try scanStringEnd(i) {
                        case .incomplete: return .needMore
                        case .ok(let end, let hasEscape):
                            let s = decodeString(i, end, hasEscape: hasEscape)
                            i = end
                            expect = afterScalar
                            return .event(.string(s))
                    }
                }
                if isJSON5, c == 0x2B || c == 0x2E || c == 0x49 || c == 0x4E {  // + . I(nfinity) N(aN)
                    switch try scanNumberEnd(i) {
                        case .incomplete: return .needMore
                        case .ok(let end):
                            let value = parseNumber(i, end)
                            i = end
                            expect = afterScalar
                            return .event(.number(value))
                    }
                }
                throw JSONError.unexpectedCharacter(c, at: i)
        }
    }

    // Returns `true` when an incomplete JSON5 comment ran to the buffer end — the caller must wait for
    // more bytes (`.needMore`) and rescan it. Plain whitespace never signals `needMore`.
    @discardableResult
    @inline(__always) private mutating func skipWS() -> Bool {
        if isJSON5 {
            let base = readOffset
            let cursor = i
            let result = buffer.withUnsafeBufferPointer { buf -> JSONToken.SkipResult in
                guard let p = unsafe buf.baseAddress.map({ unsafe $0 + base }) else {
                    return JSONToken.SkipResult(end: cursor, incomplete: false)
                }
                return unsafe JSONToken.skipInsignificant(p, cursor, count, json5: true, complete: finished)
            }
            i = result.end
            return result.incomplete
        }
        while i < count {
            let c = byte(i)
            guard c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 else { break }
            i += 1
        }
        return false
    }
}

extension JSONEventStreamReader {
    // MARK: - Resumable scanners (index-based over `buffer`; `.incomplete` means "need more bytes")

    private enum ScanOutcome {
        case ok(Int)
        case incomplete
    }

    // `.ok(end, hasEscape)`: `end` is the index past the close quote, `hasEscape` reports whether the
    // body contains a backslash (so `decodeString` skips a second scan). `.incomplete` if the buffer
    // ends mid-string.
    private enum StringScanOutcome {
        case ok(Int, Bool)
        case incomplete
    }

    // Scan a `"…"` string from the opening quote `open` via the shared grammar (Core/Tokenizer.swift).
    // `.incomplete` (buffer ended mid-token) means "wait for the next feed"; `.invalid` is malformed.
    private func scanStringEnd(_ open: Int) throws(JSONError) -> StringScanOutcome {
        let base = readOffset
        let outcome = buffer.withUnsafeBufferPointer { buf -> JSONString.ScanOutcome in
            guard let p = unsafe buf.baseAddress.map({ unsafe $0 + base }) else { return .incomplete }
            return unsafe isJSON5
                ? JSONString.scanJSON5Lexeme(p, open, count)
                : JSONString.scanLexeme(p, open, count, strict: strict)
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
        switch byte(start) {
            case 0x74: (literal, event) = ("true", .bool(true))
            case 0x66: (literal, event) = ("false", .bool(false))
            default: (literal, event) = ("null", .null)
        }
        let length = literal.utf8CodeUnitCount
        let available = Swift.min(length, count - start)
        var matched = true
        literal.withUTF8Buffer { lit in
            for k in 0 ..< available where unsafe byte(start + k) != lit[k] { matched = false }
        }
        guard matched else { throw JSONError.unexpectedCharacter(byte(start), at: start) }
        if start + length > count {
            if finished { throw JSONError.unexpectedEndOfInput }  // truncated literal, no more coming
            return .incomplete
        }
        return .ok(start + length, event)
    }
    private enum LiteralOutcome {
        case ok(Int, JSONEvent)
        case incomplete
    }

    // Loosely consume the number alphabet, then validate. Mid-stream a number that runs to the
    // buffer end is `.incomplete` (digits could continue); at `finish()` it is validated as-is.
    private func scanNumberEnd(_ start: Int) throws(JSONError) -> ScanOutcome {
        // Shared grammar (Core/Tokenizer.swift). `complete: finished` makes a lexeme that runs to the
        // buffer end `.incomplete` mid-stream but final once `finish()` has been signalled.
        let base = readOffset
        let outcome = buffer.withUnsafeBufferPointer { buf -> JSONNumber.ScanOutcome in
            guard let p = unsafe buf.baseAddress.map({ unsafe $0 + base }) else { return .incomplete }
            return unsafe isJSON5
                ? JSONNumber.scanJSON5Lexeme(p, start, count, complete: finished)
                : JSONNumber.scanLexeme(p, start, count, strict: strict, complete: finished)
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
        let base = readOffset
        return buffer.withUnsafeBufferPointer { buf in
            guard let p = unsafe buf.baseAddress.map({ unsafe $0 + base }) else { return "" }
            if !hasEscape {
                return unsafe String(decoding: UnsafeBufferPointer(start: p + start, count: length), as: UTF8.self)
            }
            return unsafe isJSON5 ? JSONString.unescapeJSON5(p, start, length) : JSONString.unescape(p, start, length)
        }
    }

    private func parseNumber(_ start: Int, _ end: Int) -> Double {
        let base = readOffset
        return buffer.withUnsafeBufferPointer { buf in
            guard let p = unsafe buf.baseAddress.map({ unsafe $0 + base }) else { return .nan }
            return unsafe JSONNumber.parseDouble(p, start, end - start)
        }
    }
}
