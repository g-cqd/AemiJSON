import Foundation
import Testing

@testable import ADJSON

private func schema(_ s: String) -> JSONSchema { try! JSONSchema(parsing: s) }
private func valid(_ schema: JSONSchema, _ json: String) -> Bool { schema.isValid(try! ADJSON.parse(json).root) }

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
    let root = try ADJSON.parse(json, options: JSONParseOptions(maxDepth: depth * 3)).root
    let compiled = JSONSchema(root)
    #expect(compiled.isValid(try ADJSON.parse(#"{"b":1}"#).root))
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
        for i in 0..<16 { group.addTask { s.isValid(try! ADJSON.parse("\(i)").root) } }
        for await r in group { #expect(r) }
    }
}
