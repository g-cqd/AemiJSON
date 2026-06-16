import ADJSON
import OrderedCollections
import Testing

// The literal conformances and result builders for constructing `JSONValue` trees.

private func objectKeys(_ value: JSONValue) -> [String]? {
    if case .object(let object) = value { return Array(object.keys) }
    return nil
}

@Suite("JSONValue builders & literals")
struct JSONBuilderTests {
    @Test func scalarLiteralsMapToCases() {
        let null: JSONValue = nil
        #expect(null == .null)
        #expect((true as JSONValue) == .bool(true))
        #expect((42 as JSONValue) == .int(42))
        #expect((3.5 as JSONValue) == .number(3.5))
        #expect(("hi" as JSONValue) == .string("hi"))
    }

    @Test func arrayAndDictionaryLiterals() throws {
        let array: JSONValue = [1, "two", true, nil]
        #expect(array == .array([.int(1), .string("two"), .bool(true), .null]))

        let object: JSONValue = ["b": 1, "a": 2]
        #expect(objectKeys(object) == ["b", "a"])  // literal order is preserved
        #expect(object == (try JSONValue(ADJSON.parse(#"{"a":2,"b":1}"#).root)))  // == is order-insensitive
    }

    @Test func makeArrayControlFlowAndEmpty() {
        let verbose = true
        let extras = ["x", "y"]
        let value = JSONValue.makeArray {
            "swift"
            for extra in extras { JSONValue.string(extra) }
            if verbose { "debug" }
            if !verbose { "quiet" }
        }
        #expect(value == .array([.string("swift"), .string("x"), .string("y"), .string("debug")]))
        #expect(JSONValue.makeArray {} == .array([]))
    }

    @Test func makeObjectNestedControlFlowAndOrder() throws {
        let email: String? = "a@b.c"
        let value = JSONValue.makeObject {
            ("id", 42)
            ("name", "Ada")
            (
                "tags",
                .makeArray {
                    "swift"
                    "json"
                }
            )
            if let email { ("email", JSONValue.string(email)) }
            ("meta", .makeObject { ("ok", true) })
        }
        let expected = try JSONValue(
            ADJSON.parse(#"{"id":42,"name":"Ada","tags":["swift","json"],"email":"a@b.c","meta":{"ok":true}}"#).root)
        #expect(value == expected)
        #expect(objectKeys(value) == ["id", "name", "tags", "email", "meta"])
    }

    @Test func makeObjectDuplicateKeyKeepsFirstPositionLastValue() {
        let value = JSONValue.makeObject {
            ("b", 1)
            ("a", 2)
            ("b", 3)
        }
        #expect(objectKeys(value) == ["b", "a"])
        if case .object(let object) = value {
            #expect(object["b"] == .int(3))
            #expect(object["a"] == .int(2))
        }
    }

    @Test func makeObjectOmittedOptionalYieldsEmpty() {
        let include = false
        let value = JSONValue.makeObject {
            if include { ("x", 1) }
        }
        #expect(objectKeys(value) == [])
    }
}
