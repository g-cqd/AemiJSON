import Testing

@testable import ADJSON

// Like the number grammar, the string/escape/identifier grammar is enforced twice: the tape
// `Scanner` (scanString / validateEscape / scanStringJSON5 / scanIdentifierKeyJSON5) and the resumable
// `JSONString` scanner behind the SAX readers. Both must accept the same language AND decode to the
// same value (they share `JSONString.unescape`). This suite feeds short, escape-heavy strings to both
// and asserts they agree on accept/reject and on the decoded contents — the contract that lets the two
// grammars stay separate without drifting.
@Suite("String/escape grammar parity (tape vs SAX)")
struct StringEscapeParityTests {
    private func tape(_ doc: String, _ options: JSONParseOptions) -> (ok: Bool, value: String?) {
        guard let parsed = try? ADJSON.parse(doc, options: options) else { return (false, nil) }
        return (true, parsed.root.string)
    }

    private func sax(_ doc: String, _ options: JSONParseOptions) -> (ok: Bool, value: String?) {
        var reader = JSONEventReader(doc, options: options)
        do {
            var first: String?
            var index = 0
            while let event = try reader.next() {
                if index == 0, case .string(let s) = event { first = s }
                index += 1
            }
            return (true, first)
        } catch { return (false, nil) }
    }

    private func assertAgree(_ doc: String, _ name: String, _ options: JSONParseOptions) {
        let t = tape(doc, options)
        let s = sax(doc, options)
        #expect(t.ok == s.ok, "string grammar diverged (\(name)) for \(doc.debugDescription): tape=\(t.ok) sax=\(s.ok)")
        if t.ok && s.ok {
            #expect(t.value == s.value, "decoded string differs (\(name)) for \(doc.debugDescription)")
        }
    }

    // All bodies of length 1...3 over an escape-focused alphabet, each wrapped in double quotes (and,
    // for JSON5, single quotes). Covers `\`, `"`, `/`, `\n`, `\u`, `\x`, `\0`, a raw control byte, and
    // every truncation of an escape — the shapes most likely to drift between two scanners.
    @Test func tapeAndSaxAgreeOnShortStrings() {
        let alphabet: [Character] = ["a", "\\", "\"", "/", "n", "u", "0", "x", "\u{01}"]
        var bodies: [String] = []
        var current: [String] = [""]
        for _ in 1...3 {
            var next: [String] = []
            next.reserveCapacity(current.count * alphabet.count)
            for prefix in current { for c in alphabet { next.append(prefix + String(c)) } }
            bodies.append(contentsOf: next)
            current = next
        }
        for body in bodies {
            assertAgree("\"\(body)\"", "strict-dq", .strict)
            assertAgree("\"\(body)\"", "json5-dq", .json5)
            assertAgree("'\(body)'", "json5-sq", .json5)
        }
    }

    // Curated escapes that single-character fuzzing won't reach: full \uXXXX, surrogate pairs, JSON5
    // hex/identity/line-continuation escapes. Agreement (not a hardcoded verdict) is the assertion.
    @Test(arguments: [
        #""é""#, #""😀""#, #""\uD800""#, #""\uDC00""#, #""\uD83D""#,
        #""\t\r\n\b\f\/\\\"""#, #""\u12""#, #""\q""#, #""\x41""#, #""\v""#, #""\0""#,
    ])
    func tapeAndSaxAgreeOnCuratedEscapes(_ doc: String) {
        assertAgree(doc, "strict", .strict)
        assertAgree(doc, "json5", .json5)
    }
}
