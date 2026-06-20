import ADJSONCore
import Testing

// The SWAR fast path in `JSONOutput.appendString` (default / `escapeSlashes` profiles) must produce
// exactly what a byte-at-a-time reference escaper produces. These tests are the gate: every escape
// class, runs that straddle the 8-byte SWAR word boundary, multi-byte UTF-8 (copied verbatim on
// encode), and both `escapeSlashes` states.

private func hexDigit(_ v: UInt8) -> UInt8 { v < 10 ? 0x30 + v : 0x61 + (v - 10) }

/// Independent reference: RFC 8259 minimal escaping, byte by byte (no SWAR).
private func reference(_ s: String, escapeSlashes: Bool) -> [UInt8] {
    var out: [UInt8] = [0x22]
    for b in s.utf8 {
        switch b {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x2F where escapeSlashes: out.append(contentsOf: [0x5C, 0x2F])
            case 0x08: out.append(contentsOf: [0x5C, 0x62])
            case 0x0C: out.append(contentsOf: [0x5C, 0x66])
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
            case 0x0D: out.append(contentsOf: [0x5C, 0x72])
            case 0x09: out.append(contentsOf: [0x5C, 0x74])
            case 0 ..< 0x20: out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hexDigit(b >> 4), hexDigit(b & 0xF)])
            default: out.append(b)
        }
    }
    out.append(0x22)
    return out
}

private func produced(_ s: String, escapeSlashes: Bool) -> [UInt8] {
    var buf: [UInt8] = []
    JSONOutput.appendString(s, to: &buf, escapeSlashes: escapeSlashes)
    return buf
}

struct EscapeSWARTests {
    @Test func matchesReferenceOnEdgeStrings() {
        let cases = [
            "", "a", "\"", "\\", "/", "\n", "\t", "\r", "\u{08}", "\u{0C}", "\u{01}", "\u{1F}",
            "hello world", "alpha bravo charlie delta echo foxtrot",
            "a\"b\\c/d\ne", "quote=\" backslash=\\ slash=/",
            "café", "中文字符串内容", "😀😀😀", "x\u{2028}y\u{2029}z", "naïve—emoji😀—é中",
            String(repeating: "a", count: 64), String(repeating: "\"", count: 20),
            "\u{01}\u{02}\u{03}\u{04}\u{05}\u{06}\u{07}\u{08}\u{09}\u{0A}\u{0B}\u{0C}\u{0D}\u{0E}\u{0F}"
        ]
        for s in cases {
            for es in [false, true] {
                #expect(produced(s, escapeSlashes: es) == reference(s, escapeSlashes: es), "‹\(s)› slashes=\(es)")
            }
        }
    }

    // A stop byte at every position of every length around the 8-byte word boundary — the SWAR bug surface.
    @Test func matchesReferenceAcrossWordBoundaries() {
        let stops: [Character] = ["\"", "\\", "/", "\n", "\u{01}"]
        for len in 0 ... 40 {
            let clean = String(repeating: "a", count: len)
            #expect(produced(clean, escapeSlashes: false) == reference(clean, escapeSlashes: false), "clean \(len)")
            for pos in 0 ..< max(len, 1) where len > 0 {
                for stop in stops {
                    var chars = Array(clean)
                    chars[pos] = stop
                    let s = String(chars)
                    for es in [false, true] {
                        #expect(
                            produced(s, escapeSlashes: es) == reference(s, escapeSlashes: es), "len=\(len) pos=\(pos)")
                    }
                }
            }
        }
    }

    @Test func matchesReferenceOnRandomStrings() {
        let pool: [Character] = [
            "a", "b", "c", " ", "z", "_", "-", "0", "9", ".", "@",
            "\"", "\\", "/", "\n", "\t", "\r", "\u{08}", "\u{0C}", "\u{01}", "\u{1F}",
            "é", "中", "😀", "\u{2028}", "\u{2029}"
        ]
        var rng = SystemRandomNumberGenerator()
        for _ in 0 ..< 30_000 {
            let len = Int.random(in: 0 ... 48, using: &rng)
            var s = ""
            for _ in 0 ..< len { s.append(pool[Int.random(in: 0 ..< pool.count, using: &rng)]) }
            let es = Bool.random(using: &rng)
            guard produced(s, escapeSlashes: es) == reference(s, escapeSlashes: es) else {
                Issue.record("mismatch slashes=\(es) bytes=\(Array(s.utf8))")
                break
            }
        }
    }
}
