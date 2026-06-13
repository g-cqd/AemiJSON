import Foundation
import Testing

@testable import ADJSON

private func parses(_ s: String, _ options: JSONParseOptions = .strict) -> Bool {
    (try? ADJSON.parse(s, options: options)) != nil
}
private func parses(_ bytes: [UInt8], _ options: JSONParseOptions = .strict) -> Bool {
    (try? ADJSON.parse(bytes, options: options)) != nil
}

@Test func strictNumberGrammar() {
    for valid in ["0", "-0", "42", "-42", "3.14", "1e10", "1E-5", "0.5", "-0.0", "123.456e+7", "0e0"] {
        #expect(parses(valid), "should accept \(valid)")
    }
    for invalid in [
        "01", "-01", "00", "1.", "-", ".5", "+5", "1e", "1e+", "1.2.3", "0x1", "--1", "Infinity", "NaN", "1.e5", "0.",
        ".",
    ] {
        #expect(!parses(invalid), "should reject \(invalid)")
    }
}

@Test func strictStringEscapesAndSurrogates() {
    #expect(parses(#""hello""#))
    #expect(parses(#""\n\t\r\"\\\/\b\f""#))
    #expect(parses(#""é""#))
    #expect(parses(#""𝄞""#))  // surrogate pair (U+1D11E)
    #expect(!parses(#""\x""#))  // invalid escape
    #expect(!parses(#""\u12""#))  // short \u
    #expect(!parses(#""\uZZZZ""#))  // non-hex
    #expect(!parses(#""\uD834""#))  // lone high surrogate
    #expect(!parses(#""\uDD1E""#))  // lone low surrogate
    #expect(!parses(#""\uD834A""#))  // high surrogate not followed by low
    #expect(!parses("\"\u{01}\""))  // unescaped control character
}

@Test func rejectsInvalidUTF8() {
    #expect(parses([0x22, 0xC3, 0xA9, 0x22]))  // "é" valid 2-byte
    #expect(parses([0x22, 0xE2, 0x82, 0xAC, 0x22]))  // "€" valid 3-byte
    #expect(!parses([0x22, 0xFF, 0x22]))  // invalid lead byte
    #expect(!parses([0x22, 0x80, 0x22]))  // lone continuation byte
    #expect(!parses([0x22, 0xC3, 0x22]))  // truncated 2-byte sequence
    #expect(!parses([0x22, 0xC0, 0x80, 0x22]))  // overlong encoding of NUL
    #expect(!parses([0x22, 0xED, 0xA0, 0x80, 0x22]))  // UTF-8-encoded surrogate U+D800
}

@Test func structuralConformance() {
    #expect(parses("{}"))
    #expect(parses("[]"))
    #expect(parses("\t [ 1 , 2 ]\n"))  // whitespace tolerated
    #expect(!parses(""))  // empty input
    #expect(!parses("{"))  // unterminated
    #expect(!parses("[1,]"))  // trailing comma
    #expect(!parses("{\"a\":1,}"))  // trailing comma in object
    #expect(!parses("[1,2] extra"))  // trailing data
    #expect(!parses("{'a':1}"))  // single-quoted key
}

@Test func duplicateKeyStrategies() throws {
    let json = #"{"a":1,"a":2,"b":3}"#
    let value = try ADJSON.parse(json).root  // default .useLast
    #expect(value["a"].int == 2)  // last wins
    #expect(value["b"].int == 3)
    #expect((try? ADJSON.parse(json, options: .iJSON)) == nil)  // I-JSON rejects duplicates
    #expect(parses(#"{"a":1,"b":2}"#, .iJSON))  // unique keys fine under I-JSON
}

@Test func lenientAcceptsWhatStrictRejects() {
    #expect(!parses("01"))
    #expect(parses("01", .lenient))
    #expect(!parses("1."))
    #expect(parses("1.", .lenient))
    #expect(!parses("[1,2,]"))  // trailing comma still rejected (structural, not strictness)
}
