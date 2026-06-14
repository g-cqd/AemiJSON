import Foundation
import Testing

@testable import ADJSON

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
