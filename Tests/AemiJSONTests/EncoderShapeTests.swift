import Foundation
import Synchronization
import Testing

@testable import AemiJSON

// Roadmap 0004. The generic encoder allocated a class per encoded value (about half of a Codable encode's mallocs): the `Encoder` handed to
// `encode(to:)` is now a value that fits an existential's inline buffer, with its container state kept by the encode. These pin the
// shape and the behavior the class gave: one container per encoder, asked for as often as the value likes.

private struct Probe: Encodable {
    let body: @Sendable (any Encoder) throws -> Void
    func encode(to encoder: any Encoder) throws { try body(encoder) }
}

private struct Twice: Encodable {
    enum K: String, CodingKey { case a, b, c }
    func encode(to encoder: any Encoder) throws {
        var first = encoder.container(keyedBy: K.self)
        try first.encode(1, forKey: .a)
        var second = encoder.container(keyedBy: K.self)
        try second.encode(2, forKey: .b)
        var list = second.nestedUnkeyedContainer(forKey: .c)
        try list.encode(Inner(values: [3, 4]))
    }
}

private struct Inner: Encodable {
    let values: [Int]
    func encode(to encoder: any Encoder) throws {
        var first = encoder.unkeyedContainer()
        try first.encode(values[0])
        var second = encoder.unkeyedContainer()
        try second.encode(values[1])
        var single = second.nestedUnkeyedContainer()
        try single.encode(Single(text: "s"))
    }
}

private struct Single: Encodable {
    let text: String
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
        _ = encoder.singleValueContainer()
    }
}

@Suite struct EncoderShapeTests {
    @Test func theEncoderHandedToEncodeIsAValue() throws {
        let seen = Mutex<[String]>([])
        let probe = Probe { encoder in
            seen.withLock { $0.append(type(of: encoder) is AnyClass ? "class \(type(of: encoder))" : "value") }
            var c = encoder.singleValueContainer()
            try c.encode(1)
        }
        _ = try AemiJSON.JSONEncoder().encode([probe, probe])
        var pretty = AemiJSON.JSONEncoder()
        pretty.prettyPrinted = true
        _ = try pretty.encode(probe)
        #expect(seen.withLock { $0 } == ["value", "value", "value"])
    }

    @Test func aContainerAskedForTwiceIsTheSameContainer() throws {
        let text = String(decoding: try AemiJSON.JSONEncoder().encode(Twice()), as: UTF8.self)
        #expect(text == #"{"a":1,"b":2,"c":[[3,4,["s"]]]}"#)
        var pretty = AemiJSON.JSONEncoder()
        pretty.prettyPrinted = true
        let theirs = Foundation.JSONEncoder()
        theirs.outputFormatting = [.prettyPrinted, .sortedKeys]
        #expect(
            String(decoding: try pretty.encode(Twice()), as: UTF8.self)
                == String(decoding: try theirs.encode(Twice()), as: UTF8.self))
    }

    @Test func customDateAndDataStrategiesStillGetAnEncoder() throws {
        struct Stamped: Encodable {
            let at: Date
            let blob: Data
        }
        var encoder = AemiJSON.JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.unkeyedContainer()
            try c.encode(Int(date.timeIntervalSince1970))
            try c.encode("s")
        }
        encoder.dataEncodingStrategy = .custom { data, encoder in
            var c = encoder.container(keyedBy: StaticKey.self)
            try c.encode(data.count, forKey: StaticKey(stringValue: "n"))
        }
        let text = String(
            decoding: try encoder.encode(Stamped(at: Date(timeIntervalSince1970: 7), blob: Data([1, 2]))), as: UTF8.self
        )
        #expect(text == #"{"at":[7,"s"],"blob":{"n":2}}"#)
    }
}

private struct StaticKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
