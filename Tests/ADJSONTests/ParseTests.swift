import Foundation
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
