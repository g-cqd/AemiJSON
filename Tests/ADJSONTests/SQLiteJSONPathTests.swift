import Foundation
import Testing

@testable import ADJSON

private func doc(_ s: String) -> JSON { try! ADJSON.parse(s).root }

private func eval(_ path: String, _ json: JSON) throws -> JSON {
    try SQLiteJSONPath(path).evaluate(json)
}

@Suite("SQLiteJSONPath")
struct SQLiteJSONPathTests {
    let object = doc(#"{"a":{"b":[10,20,30]},"c":"x","n":null}"#)

    @Test func structuralReads() throws {
        #expect(try eval("$.a.b[1]", object).int == 20)
        #expect(try eval("$.c", object).string == "x")
        #expect(try eval("$.a.b", object).isArray)
        #expect(try eval("$", object).isObject)
    }

    @Test func missingResolvesToSentinel() throws {
        #expect(try eval("$.missing", object).exists == false)
        #expect(try eval("$.a.b[9]", object).exists == false)
        #expect(try eval("$.a[0]", object).exists == false)  // index applied to an object
        #expect(try eval("$.c.d", object).exists == false)  // key applied to a string
        #expect(try eval("$.n", object).isNull)  // present, and is JSON null
    }

    @Test func quotedKeys() throws {
        let j = doc(#"{"a b":1,"a.b":2,"a\"b":3}"#)
        #expect(try eval(#"$."a b""#, j).int == 1)
        #expect(try eval(#"$."a.b""#, j).int == 2)  // dot lives inside the quoted label
        #expect(try eval(#"$."a\"b""#, j).int == 3)  // escaped quote inside the label
    }

    @Test func endRelativeAndAppend() throws {
        let a = doc("[1,2,3]")
        #expect(try eval("$[#-1]", a).int == 3)
        #expect(try eval("$[#-3]", a).int == 1)
        #expect(try eval("$[#-9]", a).exists == false)  // counted past the front
        #expect(try eval("$[#]", a).exists == false)  // the append slot is never present on read
    }

    @Test func segmentsAreExposed() throws {
        #expect(try SQLiteJSONPath("$.a[2]").segments == [.key("a"), .index(2)])
        #expect(try SQLiteJSONPath("$[#-1]").segments == [.fromEnd(1)])
        #expect(try SQLiteJSONPath("$[#]").segments == [.append])
        #expect(try SQLiteJSONPath("$").segments == [])
    }

    @Test func malformedPathsThrow() {
        #expect(throws: SQLiteJSONPathError.self) { try SQLiteJSONPath("a") }  // no leading $
        #expect(throws: SQLiteJSONPathError.self) { try SQLiteJSONPath("$x") }  // junk after $
        #expect(throws: SQLiteJSONPathError.self) { try SQLiteJSONPath("$[0") }  // missing ]
        #expect(throws: SQLiteJSONPathError.self) { try SQLiteJSONPath("$.") }  // empty label
        #expect(throws: SQLiteJSONPathError.self) { try SQLiteJSONPath("$[x]") }  // non-numeric index
    }
}
