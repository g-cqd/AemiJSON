import Testing

@testable import ADJSON

// Phase 1 content-pipeline capabilities: alloc-free compare, zero-copy span, ECMAScript number
// string, borrowed-buffer parse, and the generic JS-semantics accessors (isTruthy / jsString).

// MARK: utf8Equals

@Test func utf8EqualsMatchesUnescapedStringByBytes() throws {
    let root = try ADJSON.parse(#"{"k":"type"}"#).root
    #expect(root.k.utf8Equals("type"))
    #expect(!root.k.utf8Equals("typ"))  // shorter
    #expect(!root.k.utf8Equals("types"))  // longer
    #expect(!root.k.utf8Equals("typf"))  // same length, different bytes
}

@Test func utf8EqualsReturnsFalseForNonStringNodes() throws {
    let root = try ADJSON.parse(#"{"n":123,"b":true,"z":null,"a":[1],"o":{}}"#).root
    #expect(!root.n.utf8Equals("123"))
    #expect(!root.b.utf8Equals("true"))
    #expect(!root.z.utf8Equals("null"))
    #expect(!root.a.utf8Equals("[1]"))
    #expect(!root.o.utf8Equals("{}"))
    #expect(!root.missing.utf8Equals(""))  // absent node
}

@Test func utf8EqualsDecodesEscapedStringsToCompareContent() throws {
    // `A` → "A" and `\"` → '"' exercise the escaped (decode-once) branch.
    let root = try ADJSON.parse(#"{"u":"A","q":"a\"b"}"#).root
    #expect(root.u.string == "A")
    #expect(root.u.utf8Equals("A"))
    #expect(!root.u.utf8Equals("B"))
    #expect(root.q.string == "a\"b")
    #expect(root.q.utf8Equals("a\"b"))
}

@Test func utf8EqualsAgreesWithStringEqualsAcrossInputs() throws {
    // The contract: `json.utf8Equals(lit)` ⟺ `json.string == lit.description` for any string node.
    let root = try ADJSON.parse(#"{"plain":"hello","esc":"line\n","uni":"café","empty":""}"#).root
    func agrees(_ node: JSON, _ lit: StaticString) {
        #expect(node.utf8Equals(lit) == (node.string == lit.description))
    }
    agrees(root.plain, "hello")
    agrees(root.plain, "world")
    agrees(root.esc, "line\n")
    agrees(root.uni, "café")
    agrees(root.empty, "")
    agrees(root.empty, "x")
}

@Test func utf8EqualsMatchesEmptyString() throws {
    let root = try ADJSON.parse(#"{"e":""}"#).root
    #expect(root.e.utf8Equals(""))
    #expect(!root.e.utf8Equals("x"))
}

// MARK: withUTF8Bytes

@Test func withUTF8BytesBorrowsRawBytesOfUnescapedString() throws {
    let root = try ADJSON.parse(#"{"s":"hello"}"#).root
    let copied: [UInt8]? = root.s.withUTF8Bytes { Array($0) }
    #expect(copied == Array("hello".utf8))
}

@Test func withUTF8BytesReturnsNilForEscapedString() throws {
    let root = try ADJSON.parse(#"{"s":"a\nb"}"#).root  // \n escape sets the hasEscape flag
    var called = false
    let result: Int? = root.s.withUTF8Bytes { buf in
        called = true
        return buf.count
    }
    #expect(result == nil)
    #expect(!called)  // body must not run for the escaped (still-encoded) case
    #expect(root.s.string == "a\nb")  // the documented fallback
}

@Test func withUTF8BytesReturnsNilForNonString() throws {
    let root = try ADJSON.parse(#"{"n":123,"a":[1],"z":null}"#).root
    #expect(root.n.withUTF8Bytes { $0.count } == nil)
    #expect(root.a.withUTF8Bytes { $0.count } == nil)
    #expect(root.z.withUTF8Bytes { $0.count } == nil)
    #expect(root.missing.withUTF8Bytes { $0.count } == nil)
}

@Test func withUTF8BytesYieldsEmptyBufferForEmptyString() throws {
    let root = try ADJSON.parse(#"{"e":""}"#).root
    let count: Int? = root.e.withUTF8Bytes { $0.count }
    #expect(count == 0)  // non-nil, zero-length
}

@Test func withUTF8BytesPropagatesThrows() throws {
    struct Boom: Error {}
    let root = try ADJSON.parse(#"{"s":"x"}"#).root
    #expect(throws: Boom.self) {
        _ = try root.s.withUTF8Bytes { _ -> Int in throw Boom() }
    }
}

// MARK: ecmaNumberToString

@Test func ecmaNumberToStringMatchesKnownECMAOutputs() {
    let cases: [(Double, String)] = [
        (0, "0"), (-0.0, "0"), (1, "1"), (1.0, "1"), (-1, "-1"), (5.0, "5"),
        (100, "100"), (1000000, "1000000"), (3.14, "3.14"), (0.1, "0.1"), (0.5, "0.5"),
        (-0.25, "-0.25"), (1234.5678, "1234.5678"), (123456789, "123456789"),
        (9007199254740992, "9007199254740992"),  // 2^53
        (1e21, "1e+21"), (1e-7, "1e-7"), (1e-6, "0.000001"), (0.000001, "0.000001"),
        (1.5e300, "1.5e+300"), (-1.5e-300, "-1.5e-300"),
    ]
    for (value, expected) in cases {
        #expect(JSONOutput.ecmaNumberToString(value) == expected, "ecma(\(value))")
    }
}

@Test func ecmaNumberToStringEmitsNonFiniteTokens() {
    #expect(JSONOutput.ecmaNumberToString(.nan) == "NaN")
    #expect(JSONOutput.ecmaNumberToString(.infinity) == "Infinity")
    #expect(JSONOutput.ecmaNumberToString(-.infinity) == "-Infinity")
}

@Test func ecmaNumberToStringIsParityWithAppendECMANumber() {
    // The String convenience must agree byte-for-byte with the primitive for every finite value.
    var rng = SystemRandomNumberGenerator()
    func check(_ d: Double) {
        var bytes = [UInt8]()
        JSONOutput.appendECMANumber(d, to: &bytes)
        #expect(JSONOutput.ecmaNumberToString(d) == String(decoding: bytes, as: UTF8.self), "\(d)")
    }
    for d in [0.0, -0.0, 1.0, -1.0, 42.0, 3.14159, 1e21, 1e-7, 1e308, 5e-324] { check(d) }
    for _ in 0..<20_000 {
        let d = Double(bitPattern: UInt64.random(in: 0...UInt64.max, using: &rng))
        if d.isFinite { check(d) }
    }
}

@Test func jsNumberStringReadsNumberNodes() throws {
    let root = try ADJSON.parse(#"{"i":42,"d":2.5,"e":1e21,"neg":-0.0,"s":"x","n":null}"#).root
    #expect(root.i.jsNumberString == "42")
    #expect(root.d.jsNumberString == "2.5")
    #expect(root.e.jsNumberString == "1e+21")
    #expect(root.neg.jsNumberString == "0")  // -0 → "0"
    #expect(root.s.jsNumberString == nil)  // non-number
    #expect(root.n.jsNumberString == nil)
    #expect(root.missing.jsNumberString == nil)
}

@Test func jsNumberStringHandlesJSON5NonFiniteLiterals() throws {
    let root = try ADJSON.parse("[Infinity,-Infinity,NaN]", options: .json5).root
    let values = root.arrayValue
    #expect(values[0].jsNumberString == "Infinity")
    #expect(values[1].jsNumberString == "-Infinity")
    #expect(values[2].jsNumberString == "NaN")
}

// MARK: Borrowed-buffer parse

@Test func borrowedParseReadsValuesWithoutCopying() throws {
    let bytes = Array(#"{"a":1,"b":[1,2,3],"c":"hello","d":true,"e":null}"#.utf8)
    let copyDoc = try ADJSON.parse(bytes)
    try bytes.withUnsafeBytes { raw in
        let borrowDoc = try ADJSON.parse(raw)
        #expect(borrowDoc.root.a.int == 1)
        #expect(borrowDoc.root.c.string == "hello")
        #expect(borrowDoc.root.d.bool == true)
        #expect(borrowDoc.root.e.isNull)
        #expect(borrowDoc.root.b.arrayValue.map(\.intValue) == [1, 2, 3])
        // Structural parity with the copying entry (materialize fully inside the borrow).
        #expect(JSONValue(borrowDoc.root) == JSONValue(copyDoc.root))
    }
}

@Test func borrowedParseRejectsEmptyBuffer() {
    let empty = [UInt8]()
    empty.withUnsafeBytes { raw in
        #expect(throws: JSONError.self) { _ = try ADJSON.parse(raw) }
    }
}

@Test func borrowedParseHonorsOptions() throws {
    let bytes = Array("{a:1,/*c*/}".utf8)  // JSON5: unquoted key, comment, trailing comma
    try bytes.withUnsafeBytes { raw in
        let doc = try ADJSON.parse(raw, options: .json5)
        #expect(doc.root.a.int == 1)
    }
    bytes.withUnsafeBytes { raw in
        #expect(throws: JSONError.self) { _ = try ADJSON.parse(raw, options: .strict) }
    }
}

private struct Row: Decodable, Equatable {
    var id: Int
    var name: String
}

// The borrowed `ByteSource` is `@unchecked Sendable`; the concurrent decoder borrows it from many
// tasks at once. This exercises that path under a buffer whose lifetime is held open across the
// `await` (manual allocation + `defer`), and is run under ThreadSanitizer in CI to prove the
// read-only concurrent borrow is race-free.
@Test func borrowedParseSupportsConcurrentDecode() async throws {
    let count = 1000
    let items = (0..<count).map { #"{"id":\#($0),"name":"row\#($0)"}"# }.joined(separator: ",")
    let bytes = Array(("[" + items + "]").utf8)
    let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes.count, alignment: 1)
    defer { raw.deallocate() }
    bytes.withUnsafeBytes { raw.copyMemory(from: $0) }

    let doc = try ADJSON.parse(UnsafeRawBufferPointer(raw))
    let rows = try await ADJSON.decodeArrayConcurrently(Row.self, from: doc, minimumBatch: 64)
    #expect(rows.count == count)
    #expect(rows.first == Row(id: 0, name: "row0"))
    #expect(rows.last == Row(id: count - 1, name: "row\(count - 1)"))
}

// MARK: isTruthy

@Test func isTruthyFollowsJavaScriptRules() throws {
    let root = try ADJSON.parse(
        #"""
        {"t":true,"f":false,"nul":null,"zero":0,"negzero":-0.0,"one":1,"negone":-1,
         "fzero":0.0,"pi":3.14,"empty":"","s":"a","strzero":"0","strfalse":"false",
         "space":" ","arr":[],"arr1":[1],"obj":{},"obj1":{"k":1}}
        """#
    ).root
    #expect(root.t.isTruthy)
    #expect(!root.f.isTruthy)
    #expect(!root.nul.isTruthy)
    #expect(!root.zero.isTruthy)
    #expect(!root.negzero.isTruthy)
    #expect(root.one.isTruthy)
    #expect(root.negone.isTruthy)
    #expect(!root.fzero.isTruthy)
    #expect(root.pi.isTruthy)
    #expect(!root.empty.isTruthy)
    #expect(root.s.isTruthy)
    #expect(root.strzero.isTruthy)  // non-empty string "0" is truthy
    #expect(root.strfalse.isTruthy)  // non-empty string "false" is truthy
    #expect(root.space.isTruthy)
    #expect(root.arr.isTruthy)  // [] is truthy
    #expect(root.arr1.isTruthy)
    #expect(root.obj.isTruthy)  // {} is truthy
    #expect(root.obj1.isTruthy)
    #expect(!root.missing.isTruthy)  // undefined is falsy
}

@Test func isTruthyTreatsNaNAsFalsy() throws {
    let root = try ADJSON.parse("[NaN,Infinity]", options: .json5).root
    let v = root.arrayValue
    #expect(!v[0].isTruthy)  // NaN is falsy
    #expect(v[1].isTruthy)  // Infinity is truthy
}

@Test func isTruthyHandlesJSON5LineContinuationEmptyString() throws {
    // A JSON5 string of only a line continuation (`\` + newline) decodes to "" → falsy, even though
    // its raw bytes are non-empty.
    let root = try ADJSON.parse("{a:'\\\n'}", options: .json5).root
    #expect(root.a.string == "")
    #expect(!root.a.isTruthy)
}

// MARK: jsString

@Test func jsStringCoercesScalars() throws {
    let root = try ADJSON.parse(
        #"{"nul":null,"t":true,"f":false,"i":42,"d":3.14,"neg":-0.0,"s":"hello","e":""}"#
    ).root
    #expect(root.nul.jsString == "")
    #expect(root.t.jsString == "true")
    #expect(root.f.jsString == "false")
    #expect(root.i.jsString == "42")
    #expect(root.d.jsString == "3.14")
    #expect(root.neg.jsString == "0")
    #expect(root.s.jsString == "hello")
    #expect(root.e.jsString == "")
    #expect(root.missing.jsString == "")
}

@Test func jsStringCoercesObjectsToTag() throws {
    let root = try ADJSON.parse(#"{"o":{"a":1}}"#).root
    #expect(root.o.jsString == "[object Object]")
}

@Test func jsStringJoinsArraysLikeJavaScript() throws {
    func js(_ text: String) throws -> String { try ADJSON.parse(text).root.jsString }
    #expect(try js("[]") == "")
    #expect(try js("[1,2,3]") == "1,2,3")
    #expect(try js("[true,false]") == "true,false")
    #expect(try js(#"["a","b","c"]"#) == "a,b,c")
    #expect(try js("[null,1,null]") == ",1,")  // null elements → ""
    #expect(try js("[[],1]") == ",1")  // empty nested array contributes only its separator
    #expect(try js("[1,[2,3],4]") == "1,2,3,4")  // nested arrays flatten their separators
    #expect(try js("[[1,2],[3,4]]") == "1,2,3,4")
    #expect(try js("[[1,[2]],3]") == "1,2,3")  // deeper nesting
    #expect(try js(#"[{"a":1},2]"#) == "[object Object],2")
}

@Test func jsStringDeepArrayDoesNotOverflow() throws {
    // The iterative (explicit-stack) coercion must handle nesting far past any native-stack limit.
    let depth = 5_000
    let nested = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
    let root = try ADJSON.parse(nested, options: JSONParseOptions(maxDepth: depth + 1)).root
    #expect(root.jsString == "1")
}
