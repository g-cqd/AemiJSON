import ADFCore
import ADFKernels

// Shared, resumability-aware RFC 8259 / lenient token grammar — the single source of truth for the
// SAX readers (pull `JSONEventReader` and push `JSONEventStreamReader`). The tape `Scanner` keeps a
// separate, SWAR-integrated scan: it runs over the whole buffer in one pass, fuses int-vs-double
// classification into that pass, and never needs to suspend — whereas these helpers must be
// resumable (`.incomplete`) so a token split across feeds resumes cleanly. The two are deliberately
// distinct implementations of one grammar; `NumberGrammarParityTests` and `StringEscapeParityTests`
// bind them to the same accepted language so they cannot drift apart.
//
// Resumability is first-class: a token that reaches the buffer end while more bytes may still arrive
// returns `.incomplete`, which is exactly what the push reader needs at a chunk boundary. The
// non-streaming readers pass `complete: true`, so end-of-buffer is final rather than incomplete.
//
// These primitives are `internal` to ADJSONCore — a shared implementation detail of the readers, not
// public API (UnsafePointer-based grammar functions are not something consumers should reach for).
// Tests exercise them through `@testable import`.

extension JSONNumber {
    /// Outcome of scanning one number lexeme. `.ok(end)` gives the index just past the lexeme;
    /// `.incomplete` means the lexeme reached the buffer end and could continue (streaming only);
    /// `.invalid` means the bytes are not a well-formed number.
    enum ScanOutcome: Equatable, Sendable {
        case ok(Int)
        case incomplete
        case invalid
    }

    /// Scan a number lexeme beginning at `start` within `p[start..<count]`.
    ///
    /// - Parameters:
    ///   - p: The byte buffer being scanned.
    ///   - start: The index of the lexeme's first byte.
    ///   - count: The end of the valid bytes in `p` (exclusive).
    ///   - strict: RFC 8259 grammar (optional leading `-`, no `+`, no leading zeros, a digit required
    ///     before/after `.`); when `false`, the lenient grammar (leading `+`, bare `.5` / `5.`).
    ///   - complete: pass `true` when no more bytes will arrive (the non-streaming readers): a lexeme
    ///     that runs to `count` is then validated rather than reported `.incomplete`.
    /// - Returns: The scan outcome — the validated lexeme's extent, or `.incomplete` / a failure.
    static func scanLexeme(
        _ p: UnsafePointer<UInt8>, _ start: Int, _ count: Int, strict: Bool, complete: Bool
    ) -> ScanOutcome {
        // Phase 1 — extent: consume every byte that can appear in a number lexeme.
        var j = start
        while j < count {
            let b = unsafe p[j]
            guard (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2B || b == 0x2E || b == 0x65 || b == 0x45 else {
                break
            }
            j += 1
        }
        // A lexeme that touches the end might continue once more bytes arrive.
        if j >= count && !complete { return .incomplete }
        // Phase 2 — validate the gathered extent against the grammar.
        return unsafe validateLexeme(p, start, j, strict: strict) ? .ok(j) : .invalid
    }

    /// Validate that `p[start..<end]` is a complete, well-formed number under the `strict` (RFC 8259)
    /// or lenient grammar. The single grammar definition shared by the SAX readers.
    static func validateLexeme(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, strict: Bool) -> Bool {
        var k = start
        func digit() -> Bool { unsafe k < end && p[k] >= 0x30 && p[k] <= 0x39 }
        if k < end, unsafe p[k] == 0x2D || (!strict && p[k] == 0x2B) { k += 1 }
        guard k < end else { return false }
        if strict {
            if unsafe p[k] == 0x30 {
                k += 1
                if digit() { return false }  // no leading zero
            } else if unsafe p[k] >= 0x31 && p[k] <= 0x39 {
                k += 1
                while digit() { k += 1 }
            } else {
                return false
            }
            if k < end, unsafe p[k] == 0x2E {
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
            if k < end, unsafe p[k] == 0x2E {
                k += 1
                while digit() {
                    k += 1
                    sawDigits = true
                }
            }
            guard sawDigits else { return false }
        }
        guard unsafe validateExponent(p, &k, end) else { return false }
        return k == end
    }

    /// Validates an optional `[eE][+-]?digits` exponent suffix, advancing `k` past it.
    /// Returns false only when an `e`/`E` is present but not followed by ≥1 digit.
    private static func validateExponent(_ p: UnsafePointer<UInt8>, _ k: inout Int, _ end: Int) -> Bool {
        func digit() -> Bool { unsafe k < end && p[k] >= 0x30 && p[k] <= 0x39 }
        if k < end, unsafe p[k] == 0x65 || p[k] == 0x45 {
            k += 1
            if k < end, unsafe p[k] == 0x2B || p[k] == 0x2D { k += 1 }
            guard digit() else { return false }
            while digit() { k += 1 }
        }
        return true
    }

    /// Scan a JSON5 number lexeme starting at `start`: optional `+`/`-`, then `Infinity` / `NaN`, a
    /// hex integer (`0x…`), or a decimal allowing a leading/trailing dot (`.5`, `5.`) and exponent.
    /// `complete: true` (the non-streaming readers) turns a lexeme that runs to `count` into a final
    /// result; otherwise such a lexeme is `.incomplete`.
    static func scanJSON5Lexeme(
        _ p: UnsafePointer<UInt8>, _ start: Int, _ count: Int, complete: Bool
    ) -> ScanOutcome {
        @inline(__always) func digit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        var i = start
        if i < count, unsafe p[i] == 0x2D || p[i] == 0x2B { i += 1 }
        guard i < count else { return complete ? .invalid : .incomplete }
        if unsafe p[i] == 0x49 { return unsafe matchLiteral(p, i, count, "Infinity", complete: complete) }  // 'I'
        if unsafe p[i] == 0x4E { return unsafe matchLiteral(p, i, count, "NaN", complete: complete) }  // 'N'
        if unsafe p[i] == 0x30, i + 1 < count, unsafe p[i + 1] == 0x78 || p[i + 1] == 0x58 {  // 0x / 0X
            i += 2
            let hexStart = i
            while i < count, unsafe JSONString.isHexDigit(p[i]) { i += 1 }
            if i >= count && !complete { return .incomplete }
            return i > hexStart ? .ok(i) : .invalid
        }
        var sawDigit = false
        while i < count, unsafe digit(p[i]) {
            i += 1
            sawDigit = true
        }
        if i < count, unsafe p[i] == 0x2E {  // '.'
            i += 1
            while i < count, unsafe digit(p[i]) {
                i += 1
                sawDigit = true
            }
        }
        guard sawDigit else {
            // No digits yet: a trailing sign or lone `.` at the buffer end might still continue.
            return (i >= count && !complete) ? .incomplete : .invalid
        }
        if let outcome = unsafe scanJSON5Exponent(p, &i, count, complete: complete) { return outcome }
        return .ok(i)
    }

    /// Validates a JSON5 `[eE][+-]?digits` exponent suffix, advancing `i`. Returns a
    /// terminal `.incomplete`/`.invalid` outcome, or nil to continue to `.ok`.
    private static func scanJSON5Exponent(
        _ p: UnsafePointer<UInt8>, _ i: inout Int, _ count: Int, complete: Bool
    ) -> ScanOutcome? {
        @inline(__always) func digit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        if i < count, unsafe p[i] == 0x65 || p[i] == 0x45 {  // e / E
            i += 1
            if i < count, unsafe p[i] == 0x2B || p[i] == 0x2D { i += 1 }
            let expStart = i
            while i < count, unsafe digit(p[i]) { i += 1 }
            if i >= count && !complete { return .incomplete }
            guard i > expStart else { return .invalid }
        } else if i >= count && !complete {
            return .incomplete  // a digit run touching the end could continue
        }
        return nil
    }

    // Match a fixed ASCII literal (`Infinity` / `NaN`) at `start`. `.incomplete` if only a prefix is
    // present and more bytes may arrive; `.invalid` on any mismatch.
    private static func matchLiteral(
        _ p: UnsafePointer<UInt8>, _ start: Int, _ count: Int, _ literal: StaticString, complete: Bool
    ) -> ScanOutcome {
        let lit = unsafe literal.utf8Start
        let len = literal.utf8CodeUnitCount
        var k = 0
        while k < len {
            let idx = start + k
            if idx >= count { return complete ? .invalid : .incomplete }
            if unsafe p[idx] != lit[k] { return .invalid }
            k += 1
        }
        return .ok(start + len)
    }
}

/// Insignificant-input skipping shared by the readers: plain JSON whitespace, plus (in JSON5) the
/// extra whitespace bytes and `//` line / `/* */` block comments.
enum JSONToken {
    /// Outcome of skipping insignificant input. `end` is the next significant index; `incomplete` is
    /// `true` only in JSON5 when a `//` or `/* */` comment runs to the buffer end and more bytes may
    /// still arrive (the streaming reader must wait before deciding the comment is unterminated).
    struct SkipResult: Equatable, Sendable {
        var end: Int
        var incomplete: Bool
    }

    /// Advance past whitespace (and, when `json5`, comments) starting at `from`. `complete: true` (the
    /// non-streaming readers) treats an unterminated trailing comment as consumed to the end rather
    /// than `incomplete`.
    static func skipInsignificant(
        _ p: UnsafePointer<UInt8>, _ from: Int, _ count: Int, json5: Bool, complete: Bool
    ) -> SkipResult {
        var i = from
        while i < count {
            let c = unsafe p[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 {
                i += 1
                continue
            }
            if json5 {
                if c == 0x0B || c == 0x0C {  // vertical tab / form feed
                    i += 1
                    continue
                }
                if c == 0x2F {  // '/'
                    // On `.incomplete` we report the comment's *start*, so a streaming reader rescans
                    // it (rather than dropping the `//`/`/*` it had already consumed) on the next feed.
                    let commentStart = i
                    if i + 1 >= count {
                        if complete { break }  // a lone trailing '/' is significant (rejected later)
                        return SkipResult(end: commentStart, incomplete: true)  // might begin a comment
                    }
                    if unsafe p[i + 1] == 0x2F {  // line comment
                        var k = i + 2
                        while k < count, unsafe p[k] != 0x0A, unsafe p[k] != 0x0D { k += 1 }
                        if k >= count && !complete { return SkipResult(end: commentStart, incomplete: true) }
                        i = k
                        continue
                    }
                    if unsafe p[i + 1] == 0x2A {  // block comment
                        var k = i + 2
                        while k + 1 < count, unsafe !(p[k] == 0x2A && p[k + 1] == 0x2F) { k += 1 }
                        if k + 1 < count {  // found closing '*/'
                            i = k + 2
                            continue
                        }
                        if complete { return SkipResult(end: count, incomplete: false) }  // unterminated → EOF
                        return SkipResult(end: commentStart, incomplete: true)
                    }
                    break  // lone '/' not starting a comment (significant; rejected by the value parser)
                }
            }
            break
        }
        return SkipResult(end: i, incomplete: false)
    }
}

extension JSONString {
    /// Minimum remaining bytes for the SIMD string scan to beat the scalar loop (below it the C-call
    /// overhead dominates); short strings keep the scalar path. Matches the tape's gate.
    @usableFromInline static let kernelStringScanMinBytes = 64

    /// Outcome of scanning one `"…"` string lexeme. `.ok(end, hasEscape)` gives the index just past
    /// the closing quote and whether the body contained a backslash (so the caller can skip a second
    /// escape scan). `.incomplete` means the buffer ended mid-string / mid-escape / mid-sequence
    /// (streaming only). `.invalid` means malformed (control byte, bad escape, bad UTF-8).
    enum ScanOutcome: Equatable, Sendable {
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
    static func scanLexeme(
        _ p: UnsafePointer<UInt8>, _ open: Int, _ count: Int, strict: Bool
    ) -> ScanOutcome {
        var j = open + 1
        var hasEscape = false
        while true {
            guard j < count else { return .incomplete }
            // SIMD fast-forward over plain content to the next stop byte — control (< 0x20), non-ASCII
            // (>= 0x80), `"`, or `\` — the same stop-set as the tape's `scanString`. Short remainders
            // keep the scalar loop. In lenient mode the kernel over-stops on non-ASCII, which the
            // per-byte checks below simply skip (identical to the original scalar behavior).
            let remaining = count - j
            if remaining >= JSONString.kernelStringScanMinBytes {
                j += unsafe ADFKernels.indexOfStringStop(
                    base: p + j, count: remaining, quote: 0x22, escape: 0x5C)
                guard j < count else { return .incomplete }
            }
            let c = unsafe p[j]
            if c == 0x22 { return .ok(end: j + 1, hasEscape: hasEscape) }
            if c == 0x5C {  // escape
                hasEscape = true
                if let outcome = unsafe scanStringEscape(p, &j, count, strict: strict) { return outcome }
                continue
            }
            if c < 0x20 { return .invalid }  // unescaped control byte
            if strict && c >= 0x80 {
                guard let length = JSONUTF8.leadLength(c) else { return .invalid }
                guard j + length <= count else { return .incomplete }
                guard (try? unsafe JSONUTF8.sequenceLength(p, j, count)) != nil else { return .invalid }
                j += length
                continue
            }
            j += 1
        }
    }

    /// Validates the escape sequence at `p[j] == '\\'`, advancing `j` past it. In strict
    /// mode this enforces the JSON escape set incl. `\uXXXX` surrogate pairs; in lenient
    /// mode any byte may follow. Returns a terminal `.incomplete`/`.invalid`, or nil to
    /// continue scanning.
    private static func scanStringEscape(
        _ p: UnsafePointer<UInt8>, _ j: inout Int, _ count: Int, strict: Bool
    ) -> ScanOutcome? {
        guard j + 1 < count else { return .incomplete }
        if !strict {
            j += 2
            return nil
        }
        switch unsafe p[j + 1] {
            case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                j += 2
            case 0x75:  // \uXXXX, possibly a surrogate pair
                guard j + 6 <= count else { return .incomplete }
                guard let high = unsafe hex4(p, j + 2) else { return .invalid }
                if high >= 0xD800 && high <= 0xDBFF {
                    guard j + 12 <= count else { return .incomplete }
                    guard unsafe p[j + 6] == 0x5C, unsafe p[j + 7] == 0x75 else { return .invalid }
                    guard let low = unsafe hex4(p, j + 8), low >= 0xDC00 && low <= 0xDFFF else { return .invalid }
                    j += 12
                } else if high >= 0xDC00 && high <= 0xDFFF {
                    return .invalid  // lone low surrogate
                } else {
                    j += 6
                }
            default:
                return .invalid
        }
        return nil
    }

    /// Four hex digits at `at` (caller guarantees `at + 4` in bounds), or `nil` if any byte is not a
    /// hex digit. Uses the shared `Hex.value` table, like the tape scanner's `hex4`.
    static func hex4(_ p: UnsafePointer<UInt8>, _ at: Int) -> UInt16? {
        var value: UInt16 = 0
        for k in 0 ..< 4 {
            guard let digit = unsafe Hex.value(p[at + k]) else { return nil }
            value = (value << 4) | UInt16(digit)
        }
        return value
    }

    // One hex-digit definition for the whole engine: ADFCore's `Hex.value` table (nil = not a hex digit).
    static func isHexDigit(_ b: UInt8) -> Bool { Hex.value(b) != nil }

    /// Scan a JSON5 string starting at the opening quote `open` (a `'` or `"`); the terminator matches
    /// the opening quote. Validates the JSON5 escape set (`\x`, `\v`, `\0`, line continuations, and
    /// identity escapes). Same outcome shape as ``scanLexeme(_:_:_:strict:)``.
    static func scanJSON5Lexeme(_ p: UnsafePointer<UInt8>, _ open: Int, _ count: Int) -> ScanOutcome {
        let quote = unsafe p[open]
        var j = open + 1
        var hasEscape = false
        while true {
            guard j < count else { return .incomplete }
            let c = unsafe p[j]
            if c == quote { return .ok(end: j + 1, hasEscape: hasEscape) }
            if c == 0x5C {  // escape
                hasEscape = true
                guard j + 1 < count else { return .incomplete }
                switch unsafe escapeStepJSON5(p, j, count) {
                    case .step(let next): j = next
                    case .needMore: return .incomplete
                    case .bad: return .invalid
                }
                continue
            }
            if c < 0x20 { return .invalid }
            if c >= 0x80 {
                guard let length = JSONUTF8.leadLength(c) else { return .invalid }
                guard j + length <= count else { return .incomplete }
                guard (try? unsafe JSONUTF8.sequenceLength(p, j, count)) != nil else { return .invalid }
                j += length
                continue
            }
            j += 1
        }
    }

    private enum EscapeStep {
        case step(Int)
        case needMore, bad
    }

    // `p[j]` is a backslash (`j + 1 < count` guaranteed). Validate one JSON5 escape, returning the
    // index past it. Mirrors the tape scanner's `validateEscapeJSON5`.
    private static func escapeStepJSON5(_ p: UnsafePointer<UInt8>, _ j: Int, _ count: Int) -> EscapeStep {
        let e = unsafe p[j + 1]
        switch e {
            case 0x22, 0x27, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74, 0x76:  // " ' \ / b f n r t v
                return .step(j + 2)
            case 0x30:  // \0 — only when not followed by a decimal digit
                if j + 2 < count, unsafe p[j + 2] >= 0x30 && p[j + 2] <= 0x39 { return .bad }
                return .step(j + 2)
            case 0x31 ... 0x39:  // \1 … \9 invalid
                return .bad
            case 0x78:  // \xHH
                guard j + 3 < count else { return .needMore }
                guard unsafe isHexDigit(p[j + 2]), unsafe isHexDigit(p[j + 3]) else { return .bad }
                return .step(j + 4)
            case 0x75:  // \uHHHH (with surrogate pairing)
                guard j + 6 <= count else { return .needMore }
                guard let high = unsafe hex4(p, j + 2) else { return .bad }
                if high >= 0xD800 && high <= 0xDBFF {
                    guard j + 12 <= count else { return .needMore }
                    guard unsafe p[j + 6] == 0x5C, unsafe p[j + 7] == 0x75 else { return .bad }
                    guard let low = unsafe hex4(p, j + 8), low >= 0xDC00 && low <= 0xDFFF else { return .bad }
                    return .step(j + 12)
                } else if high >= 0xDC00 && high <= 0xDFFF {
                    return .bad
                }
                return .step(j + 6)
            case 0x0A:  // line continuation \ + LF
                return .step(j + 2)
            case 0x0D:  // line continuation \ + CR (or CRLF)
                return .step(unsafe (j + 2 < count && p[j + 2] == 0x0A) ? j + 3 : j + 2)
            default:
                if e >= 0x80 {  // identity escape of a multi-byte scalar (incl. U+2028/U+2029)
                    guard let length = JSONUTF8.leadLength(e) else { return .bad }
                    guard j + 1 + length <= count else { return .needMore }
                    guard (try? unsafe JSONUTF8.sequenceLength(p, j + 1, count)) != nil else { return .bad }
                    return .step(j + 1 + length)
                }
                return .step(j + 2)  // identity escape \X → X
        }
    }

    /// Scan a JSON5 unquoted object key (an ECMAScript IdentifierName) starting at `start`.
    /// `.ok(end, hasEscape: false)` past the identifier; `.incomplete` (streaming only) if it runs to
    /// the buffer end, where more identifier bytes might still arrive.
    static func scanIdentifier(
        _ p: UnsafePointer<UInt8>, _ start: Int, _ count: Int, complete: Bool
    ) -> ScanOutcome {
        guard start < count, unsafe isIdentStart(p[start]) else { return .invalid }
        var i = start
        if unsafe p[i] >= 0x80 {
            guard let length = unsafe JSONUTF8.leadLength(p[i]) else { return .invalid }
            if i + length > count { return complete ? .invalid : .incomplete }
            guard (try? unsafe JSONUTF8.sequenceLength(p, i, count)) != nil else { return .invalid }
            i += length
        } else {
            i += 1
        }
        while i < count {
            let c = unsafe p[i]
            if c >= 0x80 {
                guard let length = JSONUTF8.leadLength(c) else { return .invalid }
                if i + length > count { return complete ? .invalid : .incomplete }
                guard (try? unsafe JSONUTF8.sequenceLength(p, i, count)) != nil else { return .invalid }
                i += length
            } else if isIdentStart(c) || (c >= 0x30 && c <= 0x39) {
                i += 1
            } else {
                return .ok(end: i, hasEscape: false)  // stopped at a non-identifier byte
            }
        }
        return complete ? .ok(end: i, hasEscape: false) : .incomplete  // reached the buffer end
    }

    static func isIdentStart(_ b: UInt8) -> Bool {
        ((b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A) || b == 0x5F || b == 0x24 || b >= 0x80
    }
}
