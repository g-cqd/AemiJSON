import ADJSON
import Testing

// Exercises the JSON5 string un-escape branches (Core/Strings.swift `unescapeJSON5`) through the tape
// parser — the lower-covered escape paths: `\x`, `\0`, `\v`, the `\uXXXX` surrogate pair, line
// continuations (`\` + LF / CRLF / U+2028), identity escapes (ASCII and multi-byte), and raw
// multi-byte UTF-8 in strings.
struct JSON5StringEscapeTests {
    private func parse5(_ source: String) throws -> String? {
        try ADJSON.parse(source, options: .json5).root.string
    }

    @Test func hexAndShortEscapes() throws {
        #expect(try parse5(#"'\x41\x7A'"#) == "Az")
        #expect(try parse5(#"'\v\0'"#) == "\u{0B}\u{00}")
        #expect(try parse5(#"'\b\f\n\r\t'"#) == "\u{08}\u{0C}\n\r\t")
        #expect(try parse5(#"'\'\"\\\/'"#) == "'\"\\/")
    }

    @Test func unicodeEscapesAndLiterals() throws {
        let bs = "\\"  // one backslash, assembled at runtime so the source carries a real \uXXXX escape
        #expect(try parse5("'" + bs + "u0041" + bs + "u00e9'") == "Aé")  // \uXXXX escape
        #expect(try parse5("'" + bs + "uD83D" + bs + "uDE00'") == "😀")  // surrogate-pair escape → U+1F600
        #expect(try parse5(#"'Aé'"#) == "Aé")  // raw multi-byte UTF-8 (non-escape path)
        #expect(try parse5(#"'😀'"#) == "😀")  // raw 4-byte UTF-8
    }

    @Test func lineContinuationsAreElided() throws {
        #expect(try parse5("'a\\\nb'") == "ab")  // backslash + LF
        #expect(try parse5("'a\\\r\nb'") == "ab")  // backslash + CRLF
        #expect(try parse5("'a\\\u{2028}b'") == "ab")  // backslash + U+2028 line separator
    }

    @Test func identityEscapes() throws {
        #expect(try parse5(#"'\q\z'"#) == "qz")  // ASCII identity: \X → X
        #expect(try parse5("'\\é'") == "é")  // multi-byte identity escape
    }
}
