// Shared, resumability-aware RFC 8259 / lenient token grammar — the single source of truth for the
// SAX readers (pull `JSONEventReader` and push `JSONEventStreamReader`), so a grammar fix lands in
// one place instead of three. The tape `Scanner` keeps its own SWAR-integrated scan for throughput
// (a deliberate fast-path variant, see the Architecture article); these helpers are the shared,
// pointer-based grammar everything else agrees with.
//
// Resumability is first-class: a token that reaches the buffer end while more bytes may still arrive
// returns `.incomplete`, which is exactly what the push reader needs at a chunk boundary. The
// non-streaming readers pass `complete: true`, so end-of-buffer is final rather than incomplete.

extension JSONNumber {
    /// Outcome of scanning one number lexeme. `.ok(end)` gives the index just past the lexeme;
    /// `.incomplete` means the lexeme reached the buffer end and could continue (streaming only);
    /// `.invalid` means the bytes are not a well-formed number.
    public enum ScanOutcome: Equatable, Sendable {
        case ok(Int)
        case incomplete
        case invalid
    }

    /// Scan a number lexeme beginning at `start` within `p[start..<count]`.
    ///
    /// - Parameters:
    ///   - strict: RFC 8259 grammar (optional leading `-`, no `+`, no leading zeros, a digit required
    ///     before/after `.`); when `false`, the lenient grammar (leading `+`, bare `.5` / `5.`).
    ///   - complete: pass `true` when no more bytes will arrive (the non-streaming readers): a lexeme
    ///     that runs to `count` is then validated rather than reported `.incomplete`.
    @inlinable
    public static func scanLexeme(
        _ p: UnsafePointer<UInt8>, _ start: Int, _ count: Int, strict: Bool, complete: Bool
    ) -> ScanOutcome {
        // Phase 1 — extent: consume every byte that can appear in a number lexeme.
        var j = start
        while j < count {
            let b = p[j]
            if (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2B || b == 0x2E || b == 0x65 || b == 0x45 {
                j += 1
            } else {
                break
            }
        }
        // A lexeme that touches the end might continue once more bytes arrive.
        if j >= count && !complete { return .incomplete }
        // Phase 2 — validate the gathered extent against the grammar.
        return validateLexeme(p, start, j, strict: strict) ? .ok(j) : .invalid
    }

    /// Validate that `p[start..<end]` is a complete, well-formed number under the `strict` (RFC 8259)
    /// or lenient grammar. The single grammar definition shared by the SAX readers.
    @inlinable
    public static func validateLexeme(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, strict: Bool) -> Bool {
        var k = start
        func digit() -> Bool { k < end && p[k] >= 0x30 && p[k] <= 0x39 }
        if k < end, p[k] == 0x2D || (!strict && p[k] == 0x2B) { k += 1 }
        guard k < end else { return false }
        if strict {
            if p[k] == 0x30 {
                k += 1
                if digit() { return false }  // no leading zero
            } else if p[k] >= 0x31 && p[k] <= 0x39 {
                k += 1
                while digit() { k += 1 }
            } else {
                return false
            }
            if k < end, p[k] == 0x2E {
                k += 1
                guard digit() else { return false }
                while digit() { k += 1 }
            }
        } else {
            var sawDigits = false
            while digit() {
                k += 1
                sawDigits = true
            }
            if k < end, p[k] == 0x2E {
                k += 1
                while digit() {
                    k += 1
                    sawDigits = true
                }
            }
            guard sawDigits else { return false }
        }
        if k < end, p[k] == 0x65 || p[k] == 0x45 {
            k += 1
            if k < end, p[k] == 0x2B || p[k] == 0x2D { k += 1 }
            guard digit() else { return false }
            while digit() { k += 1 }
        }
        return k == end
    }
}

extension JSONString {
    /// Outcome of scanning one `"…"` string lexeme. `.ok(end, hasEscape)` gives the index just past
    /// the closing quote and whether the body contained a backslash (so the caller can skip a second
    /// escape scan). `.incomplete` means the buffer ended mid-string / mid-escape / mid-sequence
    /// (streaming only). `.invalid` means malformed (control byte, bad escape, bad UTF-8).
    public enum ScanOutcome: Equatable, Sendable {
        case ok(end: Int, hasEscape: Bool)
        case incomplete
        case invalid
    }

    /// Scan a `"…"` string starting at the opening quote `open` within `p[..<count]`. `strict`
    /// validates escapes and UTF-8 (RFC 8259 / RFC 3629); lenient skips that. Returns `.incomplete`
    /// the moment the buffer ends mid-token; each caller decides what that means — the streaming
    /// reader waits for more bytes, the whole-buffer readers treat it as truncated input. Does not
    /// decode — the caller materializes via `unescape` when `hasEscape`.
    ///
    /// Not `@inlinable`: it references the internal UTF-8 validator. It is only called from within the
    /// engine module, where the optimizer inlines it regardless.
    public static func scanLexeme(
        _ p: UnsafePointer<UInt8>, _ open: Int, _ count: Int, strict: Bool
    ) -> ScanOutcome {
        var j = open + 1
        var hasEscape = false
        while true {
            guard j < count else { return .incomplete }
            let c = p[j]
            if c == 0x22 { return .ok(end: j + 1, hasEscape: hasEscape) }
            if c == 0x5C {  // escape
                hasEscape = true
                guard j + 1 < count else { return .incomplete }
                if strict {
                    switch p[j + 1] {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                        j += 2
                    case 0x75:  // \uXXXX, possibly a surrogate pair
                        guard j + 6 <= count else { return .incomplete }
                        guard let high = hex4(p, j + 2) else { return .invalid }
                        if high >= 0xD800 && high <= 0xDBFF {
                            guard j + 12 <= count else { return .incomplete }
                            guard p[j + 6] == 0x5C, p[j + 7] == 0x75 else { return .invalid }
                            guard let low = hex4(p, j + 8), low >= 0xDC00 && low <= 0xDFFF else { return .invalid }
                            j += 12
                        } else if high >= 0xDC00 && high <= 0xDFFF {
                            return .invalid  // lone low surrogate
                        } else {
                            j += 6
                        }
                    default:
                        return .invalid
                    }
                } else {
                    j += 2
                }
                continue
            }
            if c < 0x20 { return .invalid }  // unescaped control byte
            if strict && c >= 0x80 {
                guard let length = JSONUTF8.leadLength(c) else { return .invalid }
                guard j + length <= count else { return .incomplete }
                guard (try? JSONUTF8.sequenceLength(p, j, count)) != nil else { return .invalid }
                j += length
                continue
            }
            j += 1
        }
    }

    /// Four hex digits at `at` (caller guarantees `at + 4` in bounds), or `nil` if any byte is not a
    /// hex digit.
    @inlinable
    public static func hex4(_ p: UnsafePointer<UInt8>, _ at: Int) -> UInt16? {
        var value: UInt16 = 0
        for k in 0..<4 {
            let b = p[at + k]
            let digit: UInt16
            switch b {
            case 0x30...0x39: digit = UInt16(b - 0x30)
            case 0x61...0x66: digit = UInt16(b - 0x61 + 10)
            case 0x41...0x46: digit = UInt16(b - 0x41 + 10)
            default: return nil
            }
            value = (value << 4) | digit
        }
        return value
    }
}
