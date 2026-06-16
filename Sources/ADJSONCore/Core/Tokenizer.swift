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
