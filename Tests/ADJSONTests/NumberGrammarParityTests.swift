import Testing

@testable import ADJSON

// The JSON number grammar is exercised by two engines: the tape `Scanner` (which classifies int vs
// double inline) and the shared `JSONNumber` lexeme scanner behind the SAX readers. They must accept
// exactly the same language in every mode, or the same bytes would parse on one path and fail on the
// other. This suite is the contract that lets the grammar live in one place (or stay duplicated)
// without silent drift: it feeds every short number-ish string to both and asserts they agree.
@Suite("Number grammar parity (tape vs SAX)")
struct NumberGrammarParityTests {
    // Does the tape parser accept `s` as a whole document?
    private func tapeAccepts(_ s: String, _ options: JSONParseOptions) -> Bool {
        (try? ADJSON.parse(s, options: options)) != nil
    }

    // Does the pull SAX reader (the shared `JSONNumber` lexeme grammar) accept `s` as a whole document?
    private func saxAccepts(_ s: String, _ options: JSONParseOptions) -> Bool {
        var reader = JSONEventReader(s, options: options)
        do {
            while try reader.next() != nil {}
            return true
        } catch { return false }
    }

    // All strings of length 1...maxLen over `alphabet`, built iteratively (no recursion).
    private func shortStrings(maxLen: Int, alphabet: [Character]) -> [String] {
        var all: [String] = []
        var current: [String] = [""]
        for _ in 1...maxLen {
            var next: [String] = []
            next.reserveCapacity(current.count * alphabet.count)
            for prefix in current { for c in alphabet { next.append(prefix + String(c)) } }
            all.append(contentsOf: next)
            current = next
        }
        return all
    }

    private static let modes: [(name: String, options: JSONParseOptions)] = [
        ("strict", .strict), ("lenient", .lenient), ("json5", .json5),
    ]

    // Exhaustive over a number-focused alphabet (digits, signs, dot, exponent, hex marker, and the
    // Infinity/NaN leads), so every tricky shape — `01`, `1.`, `.5`, `1e`, `+1`, `0x`, `1.2.3` — is
    // generated. The tape and SAX grammars must agree on accept/reject for each, in each mode.
    @Test func tapeAndSaxAgreeOnShortNumberishStrings() {
        let alphabet: [Character] = ["0", "1", "9", ".", "-", "+", "e", "x", "I", "N"]
        for s in shortStrings(maxLen: 4, alphabet: alphabet) {
            for mode in Self.modes {
                let tape = tapeAccepts(s, mode.options)
                let sax = saxAccepts(s, mode.options)
                #expect(
                    tape == sax,
                    "grammar diverged (\(mode.name)) for \(s.debugDescription): tape=\(tape) sax=\(sax)")
            }
        }
    }

    // Curated valid/invalid/JSON5-only literals as array elements, so the element grammar (not the
    // root-scalar path) is exercised too. Agreement is the assertion — not a hardcoded verdict.
    @Test(arguments: [
        "0", "-0", "42", "-42", "3.14", "1e10", "1E10", "1e+10", "1e-10", "0.5",
        "123456789012345678901234567890", "9007199254740993", "1.7976931348623157e308",
        "01", "1.", ".5", "+1", "1e", "1e+", "1.2.3", "--1", "0x1F", "Infinity", "NaN", "0.", "1.e3",
    ])
    func tapeAndSaxAgreeOnCuratedElements(_ literal: String) {
        for mode in Self.modes {
            let doc = "[\(literal)]"
            #expect(
                tapeAccepts(doc, mode.options) == saxAccepts(doc, mode.options),
                "grammar diverged (\(mode.name)) for element \(literal.debugDescription)")
        }
    }
}
