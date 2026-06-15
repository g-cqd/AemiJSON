import Foundation
import OrderedCollections
import Testing

@testable import ADJSON

@Test func parseDoubleMatchesDoubleStringBitExact() {
    func adj(_ s: String) -> Double {
        Array(s.utf8).withUnsafeBufferPointer { JSONNumber.parseDouble($0.baseAddress!, 0, $0.count) }
    }
    func check(_ s: String, _ sourceLocation: SourceLocation = #_sourceLocation) {
        guard let reference = Double(s) else { return }
        let mine = adj(s)
        #expect(
            mine.bitPattern == reference.bitPattern || (mine.isNaN && reference.isNaN),
            "parseDouble(\(s)) = \(mine) but Double(\(s)) = \(reference)", sourceLocation: sourceLocation)
    }

    // Explicit edge cases: zeros, 2^53 boundary, subnormals, exponent extremes, the fast/slow seam.
    for s in [
        "0", "-0", "0.0", "0e0", "1", "-1", "3.14", "-2.5", "0.1", "0.2", "0.3", "12345.6789",
        "9007199254740992", "9007199254740993", "9007199254740994",  // 2^53, 2^53+1, +2
        "1e22", "1e23", "1e-22", "1e-23", "1.7976931348623157e308", "5e-324", "2.2250738585072014e-308",
        "123456789012345", "1234567890123456", "12345678901234567", "100000000000000000000",
        "1E5", "1.0e+1", "9.999999999999999e22", "0.0000001", "-0.0",
    ] { check(s) }

    var rng = SystemRandomNumberGenerator()
    // Fast-path-targeted: significand ≤ 2^53 with an exponent in ±22 must be correctly rounded.
    for _ in 0..<50_000 {
        let sig = UInt64.random(in: 0...(1 << 53), using: &rng)
        let e = Int.random(in: -22...22, using: &rng)
        check("\(sig)e\(e)")
        check(e >= 0 ? "\(sig)" : insertPoint("\(sig)", fromEnd: -e))
    }
    // Full-precision doubles exercise the slow-path fallback (which is `Double(_:)` itself).
    for _ in 0..<20_000 {
        let d = Double(bitPattern: UInt64.random(in: 0...UInt64.max, using: &rng))
        if d.isFinite { check(d.description) }
    }
}

// Insert a decimal point `places` digits from the right of an all-digit string (padding with
// leading zeros when needed), e.g. ("12345", 3) -> "12.345", ("5", 7) -> "0.0000005".
private func insertPoint(_ digits: String, fromEnd places: Int) -> String {
    guard places > 0 else { return digits }
    if digits.count <= places { return "0." + String(repeating: "0", count: places - digits.count) + digits }
    let idx = digits.index(digits.endIndex, offsetBy: -places)
    return digits[..<idx] + "." + digits[idx...]
}

@Test func parsesAndNavigatesLazily() throws {
    let json = #"{"a":1,"b":[true,null,"x"],"c":{"d":3.5},"e":-42,"f":"a\"b"}"#
    let doc = try ADJSON.parse(json)
    let root = doc.root

    #expect(root["a"].int == 1)
    #expect(root.b[index: 0].bool == true)
    #expect(root.b[index: 1].isNull)
    #expect(root.b[index: 2].string == "x")
    #expect(root.c.d.double == 3.5)
    #expect(root.e.int == -42)
    #expect(root.f.string == "a\"b")
    #expect(root.b.count == 3)
    #expect(root["missing"].exists == false)
    #expect(root.a.string == nil)
}

@Test func materializesContainers() throws {
    let doc = try ADJSON.parse(#"{"nums":[1,2,3],"nested":{"k":"v"}}"#)
    let root = doc.root
    let nums = try #require(root.nums.array)
    #expect(nums.compactMap(\.int) == [1, 2, 3])
    let obj = try #require(root.nested.object)
    #expect(obj["k"]?.string == "v")
}

@Test func rejectsMalformed() {
    #expect(throws: JSONError.self) { try ADJSON.parse("{") }
    #expect(throws: JSONError.self) { try ADJSON.parse("[1,]") }
    #expect(throws: JSONError.self) { try ADJSON.parse("") }
    #expect(throws: JSONError.self) { try ADJSON.parse("{\"a\":1} trailing") }
}

@Test func keyBytesEqualWordCompareHandlesAllLengthsAndNearMisses() {
    // The word-at-a-time compare must agree with a byte reference across the 8-byte boundary,
    // including near-misses at the first/middle/last byte where tail bugs would hide.
    for len in 1...40 {
        let a = (0..<len).map { UInt8(($0 &* 31 &+ 7) & 0xFF) }
        let aCopy = a
        a.withUnsafeBufferPointer { pa in
            guard let ba = pa.baseAddress else { return }
            aCopy.withUnsafeBufferPointer { pc in
                if let bc = pc.baseAddress { #expect(JSONKey.bytesEqual(ba, bc, len)) }  // equal, distinct buffers
            }
            for flip in Set([0, len / 2, len - 1]) {
                var b = aCopy
                b[flip] ^= 0xFF
                b.withUnsafeBufferPointer { pb in
                    if let bb = pb.baseAddress { #expect(!JSONKey.bytesEqual(ba, bb, len)) }
                }
            }
        }
    }
    // String overload: equal, length mismatch, last-byte near-miss, and empty.
    let key = "user_name_field_01234567"  // 24 bytes = three whole words
    Array(key.utf8).withUnsafeBufferPointer { bp in
        guard let b = bp.baseAddress else { return }
        #expect(JSONKey.bytesEqual(key, b, bp.count))
        #expect(!JSONKey.bytesEqual(key + "x", b, bp.count))
        #expect(!JSONKey.bytesEqual(String(key.dropLast()) + "Z", b, bp.count))
        #expect(JSONKey.bytesEqual("", b, 0))
    }
}

@Test func deeplyNestedParsesWithoutStackOverflow() throws {
    // The iterative tape builder handles nesting far beyond any recursive parser's stack budget;
    // 10k levels would overflow recursive descent but here parse deterministically.
    let depth = 10_000
    let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
    let doc = try ADJSON.parse(nested, options: JSONParseOptions(maxDepth: depth + 1))

    // Descend via the lazy, index-based view (never materializing a recursive JSONValue, whose
    // ARC release would itself recurse).
    var node = doc.root
    var levels = 0
    while node.isArray, node.count == 1 {
        node = node[index: 0]
        levels += 1
    }
    #expect(levels == depth - 1)
    #expect(node.isArray && node.count == 0)

    // The default policy cap still rejects over-deep input — cleanly, never crashing.
    let overDefault = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
    #expect(throws: JSONError.self) { try ADJSON.parse(overDefault) }
}

@Test func parsesIntegerBoundaries() throws {
    // Regression (C1): the lazy `.int` accessor must agree with the Codable path across
    // the full Int64 range, including Int.min — which previously decoded to nil.
    let doc = try ADJSON.parse(#"[-9223372036854775808, 9223372036854775807, 0, -1]"#)
    let nums = try #require(doc.root.array)
    #expect(nums.map(\.int) == [Int.min, Int.max, 0, -1])

    let data = Data(#"[-9223372036854775808,9223372036854775807]"#.utf8)
    #expect(try ADJSON.JSONDecoder().decode([Int].self, from: data) == [Int.min, Int.max])
}

@Test func json5GrammarParsesExtensions() throws {
    func parse5(_ s: String) throws -> JSON { try ADJSON.parse(s, options: .json5).root }

    // Comments, unquoted keys, single-quoted strings, trailing commas.
    let j = try parse5(
        "{\n  // line comment\n  unquoted: 'single quoted',\n  \"quoted\": 1, /* block */\n  arr: [1, 2, 3,],\n}")
    #expect(j.unquoted.string == "single quoted")
    #expect(j.quoted.int == 1)
    #expect(j.arr.arrayValue.compactMap(\.int) == [1, 2, 3])

    // Numbers: leading +, .5, 5., hex, Infinity, NaN.
    #expect(try parse5("+5").int == 5)
    #expect(try parse5(".5").double == 0.5)
    #expect(try parse5("5.").double == 5.0)
    #expect(try parse5("0xFF").int == 255)
    #expect(try parse5("-0x10").int == -16)
    #expect(try parse5("Infinity").double == .infinity)
    #expect(try parse5("-Infinity").double == -.infinity)
    #expect(try parse5("NaN").double?.isNaN == true)

    // JSON5 string escapes: \x, \t, and a line continuation (elided).
    #expect(try parse5(#"'\x41\x42'"#).string == "AB")
    #expect(try parse5(#"'tab\tend'"#).string == "tab\tend")
    #expect(try parse5("'line1\\\nline2'").string == "line1line2")

    // Strict mode rejects every one of these.
    #expect(throws: JSONError.self) { try ADJSON.parse("{a:1}") }
    #expect(throws: JSONError.self) { try ADJSON.parse("[1,2,]") }
    #expect(throws: JSONError.self) { try ADJSON.parse("0xFF") }
    #expect(throws: JSONError.self) { try ADJSON.parse("'single'") }
    #expect(throws: JSONError.self) { try ADJSON.parse("// c\n1") }
    // And JSON5 still rejects genuinely malformed input.
    #expect(throws: JSONError.self) { try parse5("/* unterminated") }
    #expect(throws: JSONError.self) { try parse5("{a 1}") }  // missing colon
    #expect(throws: JSONError.self) { try parse5("0xZZ") }  // not hex

    // Decoder convenience property mirrors Foundation's allowsJSON5.
    struct Config: Decodable, Equatable {
        let host: String
        let port: Int
        let debug: Bool
    }
    var decoder = ADJSON.JSONDecoder()
    decoder.allowsJSON5 = true
    let cfg = try decoder.decode(
        Config.self, from: Data("{ host: 'localhost', port: 0x1F90, debug: true, /* ok */ }".utf8))
    #expect(cfg == Config(host: "localhost", port: 8080, debug: true))
}

@Test func assumesTopLevelDictionaryWrapsBracelessInput() throws {
    let opts = JSONParseOptions(assumesTopLevelDictionary: true)
    // Braceless (quoted-key) input parses as an object.
    let j = try ADJSON.parse(#""a":1,"b":[2,3]"#, options: opts).root
    #expect(j.isObject)
    #expect(j.a.int == 1)
    #expect(j.b.arrayValue.compactMap(\.int) == [2, 3])
    // Already-braced input is parsed unchanged.
    #expect(try ADJSON.parse(#"{"x":9}"#, options: opts).root.x.int == 9)
    // A single unmatched brace is still rejected on both sides.
    #expect(throws: JSONError.self) { try ADJSON.parse(#"{"a":1"#, options: opts) }  // '{…'
    #expect(throws: JSONError.self) { try ADJSON.parse(#""a":1}"#, options: opts) }  // '…}'
    // Without the option, braceless input is an error.
    #expect(throws: JSONError.self) { try ADJSON.parse(#""a":1"#) }

    // Decoder convenience property mirrors Foundation.
    struct KV: Decodable, Equatable {
        let name: String
        let count: Int
    }
    var decoder = ADJSON.JSONDecoder()
    decoder.assumesTopLevelDictionary = true
    #expect(try decoder.decode(KV.self, from: Data(#""name":"x","count":7"#.utf8)) == KV(name: "x", count: 7))
}

@Test func parseDataAndByteSourcePathsAreCorrect() throws {
    // Default parse(Data) (copy path) navigates correctly.
    let document = try ADJSON.parse(Data(#"{"a":1,"name":"héllo","arr":[1,2,3]}"#.utf8))
    #expect(document.root.a.int == 1)
    #expect(document.root.name.string == "héllo")
    #expect(document.root.arr.arrayValue.compactMap(\.int) == [1, 2, 3])

    // Opt-in zero-copy ByteSource path retains the source and is copy-on-write safe: mutating the
    // caller's Data afterward must not disturb the parsed document (it reads the retained storage).
    var data = Data(#"{"k":42,"s":"こんにちは"}"#.utf8)
    let source: any ByteSource & Sendable = data
    let zeroCopy = try ADJSON.parse(source)
    data.removeAll()
    data.append(contentsOf: Array("garbage".utf8))
    #expect(zeroCopy.root.k.int == 42)
    #expect(zeroCopy.root.s.string == "こんにちは")

    // Codable decode straight from Data works (decode borrows once, so it is the zero-copy-friendly
    // access pattern).
    struct M: Decodable, Equatable {
        let a: Int
        let name: String
        let arr: [Int]
    }
    let decoded = try ADJSON.JSONDecoder().decode(M.self, from: Data(#"{"a":1,"name":"héllo","arr":[1,2,3]}"#.utf8))
    #expect(decoded == M(a: 1, name: "héllo", arr: [1, 2, 3]))

    // Empty input is rejected cleanly on both paths (never traps on a nil base address).
    #expect(throws: JSONError.self) { try ADJSON.parse(Data()) }
    let empty: any ByteSource & Sendable = Data()
    #expect(throws: JSONError.self) { try ADJSON.parse(empty) }
}

@Test func multiByteUTF8RunsValidateAndRejectMidRun() throws {
    // The tight non-ASCII validation loop must round-trip runs that end at a quote, an escape, an
    // ASCII byte, and end-of-content — and still reject a malformed sequence *inside* a run.
    #expect(try ADJSON.parse(#""日本語テキストabc\n更に""#).root.string == "日本語テキストabc\n更に")
    #expect(try ADJSON.parse(#""🎉🚀✨""#).root.string == "🎉🚀✨")  // 4-byte run
    // Invalid continuation byte inside a run (second char's 2nd byte is 0x00, not 10xxxxxx).
    let badMidRun: [UInt8] = [0x22, 0xE6, 0x97, 0xA5, 0xE6, 0x00, 0xA5, 0x22]
    #expect(throws: JSONError.self) { try ADJSON.parse(badMidRun) }
    // Truncated 3-byte sequence terminated early by the closing quote.
    let truncated: [UInt8] = [0x22, 0xE6, 0x97, 0x22]
    #expect(throws: JSONError.self) { try ADJSON.parse(truncated) }
}

@Test func iJSONRestrictsNumbersToIEEE754Range() throws {
    // RFC 7493 §2.2: under `.iJSON`, an integer beyond ±(2^53−1) or a number overflowing to ±∞
    // is rejected; strict/lenient keep the full RFC 8259 number grammar.
    #expect(throws: JSONError.self) { try ADJSON.parse("9007199254740993", options: .iJSON) }  // 2^53+1
    #expect(throws: JSONError.self) { try ADJSON.parse("-9007199254740992", options: .iJSON) }  // −2^53
    #expect(throws: JSONError.self) { try ADJSON.parse("1e400", options: .iJSON) }  // → +∞
    #expect(throws: JSONError.self) { try ADJSON.parse("[1, 99999999999999999999]", options: .iJSON) }  // >Int64

    // In-range values stay accepted under `.iJSON` (Int64 literals are 64-bit on every platform).
    let maxSafe: Int64 = 9_007_199_254_740_991
    #expect(try ADJSON.parse("9007199254740991", options: .iJSON).root.double == Double(maxSafe))
    #expect(try ADJSON.parse("-9007199254740991", options: .iJSON).root.double == -Double(maxSafe))
    #expect(try ADJSON.parse("3.5", options: .iJSON).root.double == 3.5)
    #expect(try ADJSON.parse("1e308", options: .iJSON).root.double == 1e308)  // finite, accepted

    // strict (the default) imposes no range restriction.
    #expect(try ADJSON.parse("9007199254740993").root.exists)
    #expect(try ADJSON.parse("1e400").root.double == .infinity)
}

@Test func differentialAgainstFoundation() throws {
    let samples = [
        #"{"id":1,"name":"héllo","ok":true,"x":null}"#,
        #"[1,2,3,[4,[5,6]],{"a":{"b":[7,8]}}]"#,
        #"{"unicode":"éA","tab":"a\tb"}"#,
    ]
    for s in samples {
        let mine = try ADJSON.parse(s).root
        let foundation = try JSONSerialization.jsonObject(with: Data(s.utf8))
        assertEqual(mine, foundation)
    }
}

private func assertEqual(_ json: JSON, _ any: Any, sourceLocation: SourceLocation = #_sourceLocation) {
    switch any {
    case let dict as [String: Any]:
        let obj = json.object
        #expect(obj?.count == dict.count, sourceLocation: sourceLocation)
        for (k, v) in dict { assertEqual(json[k], v, sourceLocation: sourceLocation) }
    case let arr as [Any]:
        #expect(json.count == arr.count, sourceLocation: sourceLocation)
        for (i, v) in arr.enumerated() { assertEqual(json[index: i], v, sourceLocation: sourceLocation) }
    case is NSNull:
        #expect(json.isNull, sourceLocation: sourceLocation)
    case let s as String:
        #expect(json.string == s, sourceLocation: sourceLocation)
    case let n as NSNumber:
        // Decide by our own parsed kind to avoid NSNumber bool/int ambiguity.
        if let b = json.bool {
            #expect(b == n.boolValue, sourceLocation: sourceLocation)
        } else if let iv = json.int {
            #expect(iv == n.intValue, sourceLocation: sourceLocation)
        } else {
            #expect(json.double == n.doubleValue, sourceLocation: sourceLocation)
        }
    default:
        break
    }
}
