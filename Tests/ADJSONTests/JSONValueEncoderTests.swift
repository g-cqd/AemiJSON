import ADJSON
import Testing

struct JSONValueEncoderTests {
    @Test func encodesScalars() throws {
        #expect(try JSONValue(encoding: 42) == .int(42))
        #expect(try JSONValue(encoding: "hi") == .string("hi"))
        #expect(try JSONValue(encoding: true) == .bool(true))
        #expect(try JSONValue(encoding: 3.5) == .number(3.5))
        let none: Int? = nil
        #expect(try JSONValue(encoding: none) == .null)
    }

    enum Fruit: String, Codable { case apple, banana }
    @Test func topLevelStringFromRawValueEnum() throws {
        // The URLBuilder query-value case: an enum with a String raw value encodes to a top-level string.
        #expect(try JSONValue(encoding: Fruit.apple) == .string("apple"))
    }

    @Test func encodesArray() throws {
        #expect(try JSONValue(encoding: [1, 2, 3]) == .array([.int(1), .int(2), .int(3)]))
        #expect(try JSONValue(encoding: [String]()) == .array([]))
    }

    struct Point: Codable {
        var x: Int
        var y: Int
    }
    @Test func encodesObject() throws {
        #expect(try JSONValue(encoding: Point(x: 1, y: 2)) == .object(["x": .int(1), "y": .int(2)]))
    }

    struct Nested: Codable {
        var name: String
        var point: Point
        var tags: [String]
    }
    @Test func encodesNestedContainers() throws {
        let v = try JSONValue(encoding: Nested(name: "p", point: Point(x: 3, y: 4), tags: ["a", "b"]))
        #expect(
            v
                == .object([
                    "name": .string("p"),
                    "point": .object(["x": .int(3), "y": .int(4)]),
                    "tags": .array([.string("a"), .string("b")])
                ]))
    }

    @Test func matchesEncodeThenParse() throws {
        let value = Nested(name: "q", point: Point(x: -1, y: 9), tags: [])
        let direct = try JSONValue(encoding: value)
        let viaBytes = try JSONValue(
            parsing: String(decoding: ADJSON.JSONEncoder().encodeToBytes(value), as: UTF8.self))
        #expect(direct == viaBytes)
    }

    @Test func uint64BeyondInt64BecomesNumber() throws {
        let big = UInt64(Int64.max) + 1
        #expect(try JSONValue(encoding: big) == .number(Double(big)))
    }

    struct Opt: Codable {
        var a: Int
        var b: Int?
    }
    @Test func optionalMemberOmittedWhenNil() throws {
        #expect(try JSONValue(encoding: Opt(a: 1, b: nil)) == .object(["a": .int(1)]))
        #expect(try JSONValue(encoding: Opt(a: 1, b: 2)) == .object(["a": .int(1), "b": .int(2)]))
    }
}
