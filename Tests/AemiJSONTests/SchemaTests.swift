import Foundation
import Testing

@testable import AemiJSON

private func schema(_ s: String) -> JSONSchema { try! JSONSchema(parsing: s) }
private func valid(_ schema: JSONSchema, _ json: String) -> Bool { schema.isValid(try! AemiJSON.parse(json).root) }

@Test func validatesTypeRequiredProperties() {
    let s = schema(
        #"{"type":"object","required":["id"],"properties":{"id":{"type":"integer"},"name":{"type":"string"}}}"#)
    #expect(valid(s, #"{"id":1,"name":"x"}"#))
    #expect(valid(s, #"{"id":1}"#))
    #expect(!valid(s, #"{"name":"x"}"#))
    #expect(!valid(s, #"{"id":"nope"}"#))
    #expect(!valid(s, "[1,2]"))
}

@Test func validatesNumericAndString() {
    let n = schema(#"{"type":"number","minimum":0,"exclusiveMaximum":10,"multipleOf":0.5}"#)
    #expect(valid(n, "0"))
    #expect(valid(n, "9.5"))
    #expect(!valid(n, "-1"))
    #expect(!valid(n, "10"))
    #expect(!valid(n, "0.3"))
    let str = schema(#"{"type":"string","minLength":2,"maxLength":4,"pattern":"^a"}"#)
    #expect(valid(str, #""abc""#))
    #expect(!valid(str, #""a""#))
    #expect(!valid(str, #""abcde""#))
    #expect(!valid(str, #""xyz""#))
    #expect(valid(schema(#"{"type":"integer"}"#), "2.0"))
}

// A `pattern` is an ECMA-262 regular expression (with the `u` flag, as Ajv compiles it), run by AemiRegex's budgeted backtracker. A
// catastrophic-backtracking pattern therefore cannot hang validation: the match runs out of budget and the instance is rejected. Failing
// closed is the safe side: an input built to exhaust the budget is refused, never let through.
@Test func schemaPatternIsReDoSSafe() {
    let evil = schema(#"{"type":"string","pattern":"^(a+)+$"}"#)
    let bait = "\"" + String(repeating: "a", count: 40) + "!\""
    #expect(!valid(evil, bait))  // the budget runs out; this returns in milliseconds, not years
    #expect(valid(evil, #""aaaa""#))  // the same pattern still accepts what it should

    let safe = schema(#"{"type":"string","pattern":"^a"}"#)
    #expect(valid(safe, #""abc""#))
    #expect(!valid(safe, #""xyz""#))

    let evilProps = schema(#"{"type":"object","patternProperties":{"^(a+)+$":{"type":"integer"}}}"#)
    #expect(valid(evilProps, #"{"aaaa":1}"#))
    #expect(!valid(evilProps, #"{"aaaa":"x"}"#))
    // A key that exhausts the budget is not matched by the pattern, so the property is not constrained by it.
    #expect(valid(evilProps, #"{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!":"x"}"#))
}

// What the old safe subset refused, and the standard-library `Regex` could not run as ECMAScript does, now works: backreferences,
// look-around, named groups, Unicode properties and `\d`.
@Test func schemaPatternIsEcmaScript() {
    func json(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    func check(_ pattern: String, accepts: [String], rejects: [String]) {
        let s = schema(#"{"type":"string","pattern":\#(json(pattern))}"#)
        for text in accepts { #expect(valid(s, json(text)), "\(pattern) should accept \(text)") }
        for text in rejects { #expect(!valid(s, json(text)), "\(pattern) should reject \(text)") }
    }
    check(#"^\d{3}-\d{4}$"#, accepts: ["555-1234"], rejects: ["555-12345", "abc-1234"])
    check(#"^(\w+) \1$"#, accepts: ["hello hello"], rejects: ["hello world"])
    check(#"^(?<q>["']).*\k<q>$"#, accepts: ["'a'", "\"b\""], rejects: ["'a\""])
    check(#"^(?=.*\d)(?=.*\p{Lu}).{6,}$"#, accepts: ["abC123", "Zz9zzz"], rejects: ["abc123", "ABCDEF"])
    check(#"colou?r"#, accepts: ["my color", "colour"], rejects: ["colr"])
    check(#"^\p{Script=Greek}+$"#, accepts: ["αβγ"], rejects: ["abc"])
    check(#"^[\w.+-]+@[\w-]+\.[\w.-]+$"#, accepts: ["a.b+c@example.co.uk"], rejects: ["no-at-sign"])
    // `^` and `$` are anchors here (ECMA-262), unlike in I-Regexp.
    check("^x$", accepts: ["x"], rejects: ["^x$", "xx"])
}

@Test func aMalformedSchemaPatternIsNotEnforced() {
    // "(" is not a regular expression: the constraint is dropped, as before, and validation still works.
    let s = schema(#"{"type":"string","pattern":"("}"#)
    #expect(valid(s, #""anything""#))
}

@Test func validatesEnumConst() {
    let e = schema(#"{"enum":[1,"two",null,{"a":1}]}"#)
    #expect(valid(e, "1"))
    #expect(valid(e, #""two""#))
    #expect(valid(e, "null"))
    #expect(valid(e, #"{"a":1}"#))
    #expect(!valid(e, "2"))
    let c = schema(#"{"const":{"x":[1,2]}}"#)
    #expect(valid(c, #"{"x":[1,2]}"#))
    #expect(!valid(c, #"{"x":[1,3]}"#))
}

@Test func validatesArrays() {
    let s = schema(#"{"type":"array","minItems":1,"maxItems":3,"uniqueItems":true,"items":{"type":"integer"}}"#)
    #expect(valid(s, "[1,2,3]"))
    #expect(!valid(s, "[]"))
    #expect(!valid(s, "[1,2,3,4]"))
    #expect(!valid(s, "[1,1]"))
    #expect(!valid(s, #"[1,"x"]"#))
    let tuple = schema(#"{"type":"array","prefixItems":[{"type":"integer"},{"type":"string"}],"items":false}"#)
    #expect(valid(tuple, #"[1,"a"]"#))
    #expect(!valid(tuple, #"[1,"a",2]"#))
    #expect(!valid(tuple, #"["a",1]"#))
    let cont = schema(#"{"type":"array","contains":{"const":5},"minContains":2}"#)
    #expect(valid(cont, "[5,1,5]"))
    #expect(!valid(cont, "[5,1]"))
}

@Test func uniqueItemsRespectsSemanticEquality() {
    // The O(n) hash pass must agree with `jsonSemanticEqual`: numbers by value, objects unordered.
    let s = schema(#"{"type":"array","uniqueItems":true}"#)
    #expect(!valid(s, "[1,1.0]"))  // same JSON number
    #expect(!valid(s, #"[{"a":1,"b":2},{"b":2,"a":1}]"#))  // objects equal regardless of key order
    #expect(!valid(s, #"[{"a":{"b":[1,2,3]}},{"a":{"b":[1,2,3]}}]"#))  // deep duplicate still caught
    // Distinct (but similar) nested values stay unique — the hash bucketing must not false-positive.
    #expect(valid(s, #"[{"a":[1,2]},{"a":[1,3]},{"a":[2,1]}]"#))
    #expect(valid(s, "[1,2,3,4,5]"))
}

@Test func multipleOfUsesExactIntegerModulo() {
    // Large integers: the old relative-epsilon test grew its tolerance to ~10² near 10¹², so a
    // non-multiple wrongly passed. Exact integer modulo (both operands integral, < 2^53) fixes it.
    let s = schema(#"{"multipleOf":7}"#)
    #expect(valid(s, "999999999999"))  // 7 × 142857142857
    #expect(!valid(s, "1000000000000"))
    #expect(!valid(s, "1000000000001"))
    // Genuine fractions still use the epsilon path.
    #expect(valid(schema(#"{"multipleOf":0.1}"#), "0.3"))
    #expect(!valid(schema(#"{"multipleOf":0.5}"#), "0.3"))
}

@Test func validatesCombinatorsAndConditional() {
    let any = schema(#"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#)
    #expect(valid(any, #""x""#))
    #expect(valid(any, "5"))
    #expect(!valid(any, "true"))
    let one = schema(#"{"oneOf":[{"type":"number","multipleOf":2},{"type":"number","multipleOf":3}]}"#)
    #expect(valid(one, "4"))
    #expect(valid(one, "9"))
    #expect(!valid(one, "6"))
    let not = schema(#"{"not":{"type":"null"}}"#)
    #expect(valid(not, "1"))
    #expect(!valid(not, "null"))
    let cond = schema(
        #"{"if":{"required":["t"],"properties":{"t":{"const":"a"}}},"then":{"required":["a"]},"else":{"required":["b"]}}"#
    )
    #expect(valid(cond, #"{"t":"a","a":1}"#))
    #expect(!valid(cond, #"{"t":"a"}"#))
    #expect(valid(cond, #"{"t":"x","b":1}"#))
}

@Test func validatesRefAndDefsIncludingRecursive() {
    let s = schema(##"{"type":"array","items":{"$ref":"#/$defs/pos"},"$defs":{"pos":{"type":"integer","minimum":0}}}"##)
    #expect(valid(s, "[0,1,2]"))
    #expect(!valid(s, "[1,-2]"))
    let tree = schema(
        ##"{"$ref":"#/$defs/node","$defs":{"node":{"type":"object","properties":{"children":{"type":"array","items":{"$ref":"#/$defs/node"}}}}}}"##
    )
    #expect(valid(tree, #"{"children":[{"children":[]},{}]}"#))
    #expect(!valid(tree, #"{"children":"no"}"#))
}

@Test func refCycleTerminatesInsteadOfRecursingForever() {
    // a → b → a with no instance consumption would recurse until the stack overflows without
    // the cycle guard; with it, validation terminates (no constraints along the cycle).
    let s = schema(##"{"$ref":"#/$defs/a","$defs":{"a":{"$ref":"#/$defs/b"},"b":{"$ref":"#/$defs/a"}}}"##)
    #expect(valid(s, "1"))
}

@Test func deeplyNestedSchemaCompilesWithoutStackOverflow() throws {
    // The iterative compiler must build a deep node table without recursing; 2k levels would
    // overflow recursive compilation. (Validation stays shallow — the instance lacks the nested
    // key — so the still-recursive validator isn't exercised.)
    let depth = 2000
    let json =
        String(repeating: #"{"properties":{"a":"#, count: depth) + #"{"type":"integer"}"#
        + String(repeating: "}}", count: depth)
    let root = try AemiJSON.parse(json, options: JSONParseOptions(maxDepth: depth * 3)).root
    let compiled = JSONSchema(root)
    #expect(compiled.isValid(try AemiJSON.parse(#"{"b":1}"#).root))
}

@Test func validatesAdditionalAndDependent() {
    let s = schema(#"{"type":"object","properties":{"a":{"type":"integer"}},"additionalProperties":false}"#)
    #expect(valid(s, #"{"a":1}"#))
    #expect(!valid(s, #"{"a":1,"b":2}"#))
    let dep = schema(#"{"dependentRequired":{"card":["cvv"]}}"#)
    #expect(valid(dep, #"{"card":1,"cvv":2}"#))
    #expect(!valid(dep, #"{"card":1}"#))
    #expect(valid(dep, #"{"x":1}"#))
}

@Test func compiledSchemaValidatesConcurrently() async {
    let s = schema(#"{"type":"integer","minimum":0}"#)
    await withTaskGroup(of: Bool.self) { group in
        for i in 0 ..< 16 { group.addTask { s.isValid(try! AemiJSON.parse("\(i)").root) } }
        for await r in group { #expect(r) }
    }
}
