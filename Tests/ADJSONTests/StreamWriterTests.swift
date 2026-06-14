import Foundation
import Testing

@testable import ADJSON

private func emit(_ build: (inout JSONStreamWriter) -> Void, options: JSONEncodingOptions = .javaScript) -> String {
    var w = JSONStreamWriter(options: options)
    build(&w)
    return String(decoding: w.finish(), as: UTF8.self)
}

// Golden vector: each input must serialize byte-for-byte like JavaScript `JSON.stringify(n)`.
@Test(arguments: [
    (0.0, "0"), (-0.0, "0"), (1.0, "1"), (-1.0, "-1"), (5.0, "5"), (123.0, "123"),
    (100.0, "100"), (0.1, "0.1"), (0.5, "0.5"), (1.5, "1.5"), (-0.25, "-0.25"),
    (3.14159, "3.14159"), (1234.5678, "1234.5678"), (1000000.0, "1000000"),
    (1e21, "1e+21"), (1e-7, "1e-7"), (0.0000001, "1e-7"), (1e-6, "0.000001"),
    (1e20, "100000000000000000000"), (1.5e300, "1.5e+300"), (2.5e-8, "2.5e-8"),
    (9007199254740992.0, "9007199254740992"), (-1.5e-10, "-1.5e-10"),
])
func ecma262NumberMatchesJSONStringify(_ input: Double, _ expected: String) {
    #expect(emit { $0.number(input) } == expected)
}

@Test func streamWriterAutoCommaStructure() {
    let s = emit { w in
        w.beginObject()
        w.key("a")
        w.integer(1)
        w.key("b")
        w.beginArray()
        w.integer(2)
        w.integer(3)
        w.endArray()
        w.key("c")
        w.string("x")
        w.endObject()
    }
    #expect(s == #"{"a":1,"b":[2,3],"c":"x"}"#)
    // Top-level fragment and a nested array of objects.
    #expect(emit { $0.integer(42) } == "42")
    #expect(
        emit { w in
            w.beginArray()
            w.beginObject()
            w.key("a")
            w.integer(1)
            w.endObject()
            w.beginObject()
            w.key("b")
            w.integer(2)
            w.endObject()
            w.endArray()
        } == #"[{"a":1},{"b":2}]"#)
}

// The two load-bearing cases from the request: caller-ordered dynamic keys and verbatim splice.
@Test func streamWriterDynamicKeysAndRawSplice() {
    let rows: [(String, String)] = [("z", "1"), ("a", "2"), ("m", "3")]  // intentionally unsorted
    let ordered = emit { w in
        w.beginObject()
        for (k, v) in rows {
            w.key(k)
            w.string(v)
        }
        w.endObject()
    }
    #expect(ordered == #"{"z":"1","a":"2","m":"3"}"#)  // caller order preserved, no sort/dedup

    let spliced = emit { w in
        w.beginObject()
        w.key("id")
        w.integer(7)
        w.key("profile")
        w.raw(#"{"name":"Z"}"#)
        w.key("tags")
        w.rawOrEmptyArray(nil)
        w.key("note")
        w.rawOrNull(nil)
        w.endObject()
    }
    #expect(spliced == #"{"id":7,"profile":{"name":"Z"},"tags":[],"note":null}"#)
}

@Test func streamWriterRawValidatedRejectsMalformed() {
    let ok = emit { w in
        w.beginArray()
        try? w.rawValidated("123")
        try? w.rawValidated(#"{"k":true}"#)
        w.endArray()
    }
    #expect(ok == #"[123,{"k":true}]"#)
    #expect(throws: JSONError.self) {
        var w = JSONStreamWriter()
        try w.rawValidated("{bad")
    }
}

@Test func streamWriterJSStringEscaping() {
    // `"`, `\`, and control chars escape (lowercase `\u00xx`); `/` does NOT escape (JS parity).
    let esc = String(UnicodeScalar(0x1B)!)  // ESC control char built without a raw byte in source
    #expect(emit { $0.string("a\"b\\c/" + esc) } == "\"a\\\"b\\\\c/\\u001b\"")
    // Opt-in slash escaping.
    #expect(emit({ $0.string("a/b") }, options: JSONEncodingOptions(escapeSlashes: true)) == "\"a\\/b\"")
}

@Test func streamWriterNonFiniteIsNullUnderJSProfile() {
    #expect(
        emit { w in
            w.beginArray()
            w.number(.infinity)
            w.number(.nan)
            w.number(-.infinity)
            w.endArray()
        } == "[null,null,null]")
    #expect(emit { $0.stringOrNull(nil) } == "null")
}

@Test func streamWriterZeroCopyAccessors() {
    var w = JSONStreamWriter()
    w.beginArray()
    w.integer(1)
    w.integer(2)
    w.endArray()
    let viaUnsafe = w.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
    #expect(viaUnsafe == "[1,2]")
    #expect(String(decoding: w.finish(), as: UTF8.self) == "[1,2]")
}
