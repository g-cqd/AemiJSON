import Foundation
import Testing

@testable import AemiJSON

// Roadmap 0003. The writer's buffer and the encode state's frame stacks are exempt from the run-time exclusivity check, on the argument
// that every access is a short in-place append or bump that never spans a call into user code. These encodes re-enter the encoder from
// user code in every way the protocol allows (nested keyed and unkeyed containers, `superEncoder`, a `@JSONCodable` value inside a
// generic one, recursion) and must write what Foundation writes.

@JSONCodable
private struct FastLeaf: Codable {
    var x: Int
    var label: String
}

private struct Reentrant: Encodable {
    let depth: Int

    private struct K: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(depth, forKey: K(stringValue: "depth"))
        var nested = c.nestedContainer(keyedBy: K.self, forKey: K(stringValue: "nested"))
        try nested.encode(FastLeaf(x: depth, label: "leaf \(depth)"), forKey: K(stringValue: "fast"))
        try nested.encode([1.5, -0.25], forKey: K(stringValue: "doubles"))
        var list = c.nestedUnkeyedContainer(forKey: K(stringValue: "list"))
        if depth > 0 {
            try list.encode(Reentrant(depth: depth - 1))
            var inner = list.nestedUnkeyedContainer()
            try inner.encode("in")
            try inner.encode(Reentrant(depth: depth - 1))
        }
        try list.encode(true)
        try Reentrant.Leaf(value: depth).encode(to: c.superEncoder(forKey: K(stringValue: "sup")))
        try c.encode("end", forKey: K(stringValue: "tail"))
    }

    private struct Leaf: Encodable {
        let value: Int
    }
}

/// Parsed by Foundation, so two encodings compare as values whatever their key order.
private func foundationValue(_ bytes: some Sequence<UInt8>) throws -> NSObject {
    try JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]) as! NSObject
}

@Suite struct ReentrantEncodeTests {
    // Foundation's own key order is unspecified, so the streams are compared as values, and byte for byte with sorted keys.
    @Test(arguments: [0, 1, 3])
    func reentrantEncodeMatchesFoundation(depth: Int) throws {
        let value = Reentrant(depth: depth)
        let mine = try AemiJSON.JSONEncoder().encode(value)
        let theirs = try Foundation.JSONEncoder().encode(value)
        #expect(try foundationValue(mine) == foundationValue(theirs))
    }

    @Test(arguments: [false, true])
    func reentrantSortedEncodeMatchesFoundationByteForByte(pretty: Bool) throws {
        let value = Reentrant(depth: 2)
        var mine = AemiJSON.JSONEncoder()
        mine.options.keyOrder = .sorted
        mine.prettyPrinted = pretty
        let theirs = Foundation.JSONEncoder()
        theirs.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        #expect(
            String(decoding: try mine.encode(value), as: UTF8.self)
                == String(decoding: try theirs.encode(value), as: UTF8.self))
    }

    /// The streaming writer's own order is the order of the calls.
    @Test func reentrantEncodeKeepsTheOrderOfTheCalls() throws {
        let text = String(decoding: try AemiJSON.JSONEncoder().encode(Reentrant(depth: 1)), as: UTF8.self)
        let leaf0 =
            #"{"depth":0,"nested":{"fast":{"x":0,"label":"leaf 0"},"doubles":[1.5,-0.25]},"list":[true],"sup":{"value":0},"tail":"end"}"#
        let expected =
            #"{"depth":1,"nested":{"fast":{"x":1,"label":"leaf 1"},"doubles":[1.5,-0.25]},"list":["#
            + leaf0 + #",["in","# + leaf0 + #"],true],"sup":{"value":1},"tail":"end"}"#
        #expect(text == expected)
    }

    @Test func reentrantPrettyEncodeParsesToTheSameValue() throws {
        let value = Reentrant(depth: 2)
        var mine = AemiJSON.JSONEncoder()
        mine.prettyPrinted = true
        #expect(try foundationValue(mine.encode(value)) == foundationValue(Foundation.JSONEncoder().encode(value)))
    }
}
