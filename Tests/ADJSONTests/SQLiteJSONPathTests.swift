import Foundation
import Testing

@testable import ADJSON

private func doc(_ s: String) -> JSON { try! ADJSON.parse(s).root }

private func eval(_ path: String, _ json: JSON) throws -> JSON {
    try SQLiteJSONPath(path).evaluate(json)
}

private func spath(_ s: String) -> SQLiteJSONPath { try! SQLiteJSONPath(s) }
private func jvalue(_ s: String) -> JSONValue { try! JSONValue(parsing: s) }

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

@Suite("SQLiteJSON functions")
struct SQLiteJSONFunctionTests {
    @Test func typeAndArrayLength() {
        let j = doc(#"{"o":{},"a":[1,2,3],"i":5,"r":5.5,"s":"x","t":true,"f":false,"n":null}"#)
        #expect(SQLiteJSON.type(j) == "object")
        #expect(SQLiteJSON.type(j.a) == "array")
        #expect(SQLiteJSON.type(j.i) == "integer")
        #expect(SQLiteJSON.type(j.r) == "real")
        #expect(SQLiteJSON.type(j.s) == "text")
        #expect(SQLiteJSON.type(j.t) == "true")
        #expect(SQLiteJSON.type(j.f) == "false")
        #expect(SQLiteJSON.type(j.n) == "null")
        #expect(SQLiteJSON.type(j.missing) == nil)
        #expect(SQLiteJSON.arrayLength(j.a) == 3)
        #expect(SQLiteJSON.arrayLength(j.o) == 0)
    }

    @Test func valid() {
        #expect(SQLiteJSON.valid("{}"))
        #expect(SQLiteJSON.valid(#"{"a":[1,2,3]}"#))
        #expect(!SQLiteJSON.valid("{a:1}"))
        #expect(!SQLiteJSON.valid("nope"))
    }

    @Test func arrowVsArrowText() {
        let j = doc(#"{"s":"hi","i":5,"r":2.5,"t":true,"n":null,"o":{"x":1},"a":[1,2]}"#)
        // -> returns the JSON node (a string serializes quoted); ->> returns unquoted text.
        #expect(spath("$.s").arrow(j).string == "hi")
        #expect(spath("$.s").arrowText(j) == "hi")
        #expect(spath("$.i").arrowText(j) == "5")
        #expect(spath("$.r").arrowText(j) == "2.5")
        #expect(spath("$.t").arrowText(j) == "true")
        #expect(spath("$.n").arrowText(j) == nil)  // JSON null → SQL NULL
        #expect(spath("$.missing").arrowText(j) == nil)
        #expect(spath("$.o").arrowText(j) == #"{"x":1}"#)  // container → JSON text
        #expect(spath("$.a").arrowText(j) == "[1,2]")
    }

    @Test func extractSingleAndMultiPath() {
        let j = doc(#"{"i":5,"s":"hi"}"#)
        #expect(SQLiteJSON.extract(j, [spath("$.i")]) == .number(5))  // single → the value
        #expect(
            SQLiteJSON.extract(j, [spath("$.i"), spath("$.s"), spath("$.missing")])
                == .array([.number(5), .string("hi"), .null]))  // multi → array, missing → null
    }

    private let base = jvalue(#"{"a":1,"b":[10,20]}"#)

    @Test func jsonSet() {
        #expect(spath("$.a").set(.number(2), in: base) == jvalue(#"{"a":2,"b":[10,20]}"#))  // overwrite
        #expect(spath("$.c").set(.bool(true), in: base) == jvalue(#"{"a":1,"b":[10,20],"c":true}"#))  // create
        #expect(spath("$.x.y").set(.number(1), in: base) == base)  // missing parent → no-op
        #expect(spath("$.b[0]").set(.number(99), in: base) == jvalue(#"{"a":1,"b":[99,20]}"#))  // index
        #expect(spath("$.b[#-1]").set(.number(21), in: base) == jvalue(#"{"a":1,"b":[10,21]}"#))  // from end
        #expect(spath("$.b[#]").set(.number(30), in: base) == jvalue(#"{"a":1,"b":[10,20,30]}"#))  // append
    }

    @Test func jsonInsertAndReplace() {
        #expect(spath("$.a").insert(.number(9), in: base) == base)  // exists → no-op
        #expect(spath("$.c").insert(.number(3), in: base) == jvalue(#"{"a":1,"b":[10,20],"c":3}"#))  // create
        #expect(spath("$.a").replace(.number(7), in: base) == jvalue(#"{"a":7,"b":[10,20]}"#))  // overwrite
        #expect(spath("$.c").replace(.number(7), in: base) == base)  // missing → no-op
    }

    @Test func jsonRemove() {
        #expect(spath("$.a").remove(in: base) == jvalue(#"{"b":[10,20]}"#))
        #expect(spath("$.b[0]").remove(in: base) == jvalue(#"{"a":1,"b":[20]}"#))
        #expect(spath("$.missing").remove(in: base) == base)  // no-op
    }

    @Test func jsonPatchMergesRFC7396() {
        let target = jvalue(#"{"a":1,"b":{"x":1,"y":2}}"#)
        let patch = jvalue(#"{"b":{"y":null,"z":3},"c":4}"#)
        #expect(SQLiteJSON.patch(target, with: patch) == jvalue(#"{"a":1,"b":{"x":1,"z":3},"c":4}"#))
    }

    @Test func jsonQuote() {
        #expect(SQLiteJSON.quote(.number(3.5)) == "3.5")
        #expect(SQLiteJSON.quote(.number(5)) == "5")  // integral double collapses, like a JSON int
        #expect(SQLiteJSON.quote(.string("verdant")) == #""verdant""#)
        #expect(SQLiteJSON.quote(.string("a\"b")) == #""a\"b""#)  // quote escaped
        #expect(SQLiteJSON.quote(.bool(true)) == "true")
        #expect(SQLiteJSON.quote(.null) == "null")
        #expect(SQLiteJSON.quote(.array([.number(1), .number(2)])) == "[1,2]")
        #expect(SQLiteJSON.quote(.number(.infinity)) == "null")  // non-finite → well-formed null
    }

    @Test func jsonEach() {
        // Object: one row per member; key set, index nil; full path; type per value.
        let obj = doc(#"{"a":1,"b":[10,20],"c":"x"}"#)
        let objRows = Array(SQLiteJSON.each(obj))
        #expect(objRows.map(\.key) == ["a", "b", "c"])
        #expect(objRows.allSatisfy { $0.index == nil })
        #expect(objRows.map(\.type) == ["integer", "array", "text"])
        #expect(objRows.map(\.path) == ["$.a", "$.b", "$.c"])
        #expect(objRows[0].value.int == 1)

        // Array: one row per element; index set, key nil.
        let arrRows = Array(SQLiteJSON.each(doc("[10,20,30]")))
        #expect(arrRows.map(\.index) == [0, 1, 2])
        #expect(arrRows.allSatisfy { $0.key == nil })
        #expect(arrRows.map(\.path) == ["$[0]", "$[1]", "$[2]"])

        // Scalar: a single self-row at `$`.
        let scalarRows = Array(SQLiteJSON.each(doc("42")))
        #expect(scalarRows.count == 1)
        #expect(scalarRows[0].path == "$" && scalarRows[0].type == "integer")
        #expect(scalarRows[0].value.int == 42)

        // Empty container / missing: no rows.
        #expect(Array(SQLiteJSON.each(doc("{}"))).isEmpty)
        #expect(Array(SQLiteJSON.each(doc("[]"))).isEmpty)
        #expect(Array(SQLiteJSON.each(doc(#"{"a":1}"#).missing)).isEmpty)
    }

    @Test func jsonEachQuotesSpecialKeysAndRoundTrips() throws {
        let j = doc(#"{"a b":1,"a.b":2}"#)
        let rows = Array(SQLiteJSON.each(j))
        #expect(rows.map(\.path) == [#"$."a b""#, #"$."a.b""#])
        // Each generated path re-parses through SQLiteJSONPath and resolves to the same value.
        for row in rows {
            #expect(try SQLiteJSONPath(row.path).evaluate(j).int == row.value.int)
        }
    }

    @Test func jsonTreePreorderWithFullPaths() throws {
        let j = doc(#"{"a":1,"b":{"c":[2,3]}}"#)
        let rows = Array(SQLiteJSON.tree(j))
        // Preorder, root first: $, $.a, $.b, $.b.c, $.b.c[0], $.b.c[1].
        #expect(rows.map(\.path) == ["$", "$.a", "$.b", "$.b.c", "$.b.c[0]", "$.b.c[1]"])
        #expect(rows.map(\.type) == ["object", "integer", "object", "array", "integer", "integer"])
        #expect(rows[0].key == nil && rows[0].index == nil)  // root
        #expect(rows[1].key == "a")
        #expect(rows[4].index == 0)
        // Every path resolves back to a present node.
        for row in rows { #expect(try SQLiteJSONPath(row.path).evaluate(j).exists) }
    }

    @Test func jsonTreeDeepStreamsWithoutOverflow() throws {
        let depth = 1000
        let nested = String(repeating: #"{"x":"#, count: depth) + "1" + String(repeating: "}", count: depth)
        let j = try ADJSON.parse(nested, options: JSONParseOptions(maxDepth: depth + 1)).root
        var count = 0
        for _ in SQLiteJSON.tree(j) { count += 1 }
        #expect(count == depth + 1)  // `depth` nested objects + the innermost number
    }
}
