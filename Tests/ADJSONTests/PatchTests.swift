import Foundation
import Testing

@testable import ADJSON

private func jv(_ s: String) -> JSONValue { try! JSONValue(parsing: s) }
private func applyPatch(_ patch: String, to target: String) throws -> JSONValue {
    try JSONPatch(Data(patch.utf8)).apply(to: jv(target))
}

@Test func rfc6902Examples() throws {
    // A.1 add an object member
    #expect(
        try applyPatch(#"[{"op":"add","path":"/baz","value":"qux"}]"#, to: #"{"foo":"bar"}"#)
            == jv(#"{"foo":"bar","baz":"qux"}"#))
    // A.2 add an array element
    #expect(
        try applyPatch(#"[{"op":"add","path":"/foo/1","value":"qux"}]"#, to: #"{"foo":["bar","baz"]}"#)
            == jv(#"{"foo":["bar","qux","baz"]}"#))
    // A.3 remove
    #expect(
        try applyPatch(#"[{"op":"remove","path":"/baz"}]"#, to: #"{"baz":"qux","foo":"bar"}"#) == jv(#"{"foo":"bar"}"#))
    // A.5 replace
    #expect(
        try applyPatch(#"[{"op":"replace","path":"/baz","value":"boo"}]"#, to: #"{"baz":"qux","foo":"bar"}"#)
            == jv(#"{"baz":"boo","foo":"bar"}"#))
    // A.6 move (object)
    #expect(
        try applyPatch(
            #"[{"op":"move","from":"/foo/waldo","path":"/qux/thud"}]"#,
            to: #"{"foo":{"bar":"baz","waldo":"fred"},"qux":{"corge":"grault"}}"#)
            == jv(#"{"foo":{"bar":"baz"},"qux":{"corge":"grault","thud":"fred"}}"#))
    // A.7 move (array reorder)
    #expect(
        try applyPatch(
            #"[{"op":"move","from":"/foo/1","path":"/foo/3"}]"#, to: #"{"foo":["all","grass","cows","eat"]}"#)
            == jv(#"{"foo":["all","cows","eat","grass"]}"#))
    // copy + append with "-"
    #expect(
        try applyPatch(#"[{"op":"copy","from":"/foo/0","path":"/foo/-"}]"#, to: #"{"foo":["a","b"]}"#)
            == jv(#"{"foo":["a","b","a"]}"#))
    // test success leaves the document unchanged
    #expect(
        try applyPatch(#"[{"op":"test","path":"/baz","value":"qux"}]"#, to: #"{"baz":"qux"}"#) == jv(#"{"baz":"qux"}"#))
}

@Test func rfc6902TestFailureThrows() {
    #expect(throws: JSONPatchError.self) {
        try JSONPatch(Data(#"[{"op":"test","path":"/a","value":1}]"#.utf8)).apply(to: jv(#"{"a":2}"#))
    }
    #expect(throws: JSONPatchError.self) {
        try JSONPatch(Data(#"[{"op":"remove","path":"/missing"}]"#.utf8)).apply(to: jv(#"{"a":1}"#))
    }
}

@Test func rfc6902RejectsMoveIntoOwnChild() {
    // RFC 6902 §4.4: a location cannot be moved into one of its children.
    #expect(throws: JSONPatchError.self) {
        try JSONPatch(Data(#"[{"op":"move","from":"/a","path":"/a/b"}]"#.utf8)).apply(to: jv(#"{"a":{"b":1}}"#))
    }
}

@Test func rfc6901RejectsNonCanonicalArrayIndex() throws {
    // RFC 6901 §4: array index is "0" or [1-9][0-9]* — no leading zero or '+'.
    let doc = try ADJSON.parse(#"{"a":["x","y"]}"#).root
    #expect(doc[pointer: "/a/0"].string == "x")
    #expect(doc[pointer: "/a/01"].exists == false)
    #expect(doc[pointer: "/a/+1"].exists == false)
    let v = try JSONValue(parsing: #"{"a":["x","y"]}"#)
    #expect(v.value(at: try JSONPointer("/a/01")) == nil)
    #expect(v.value(at: try JSONPointer("/a/1")) == .string("y"))
}

@Test func rfc7396MergePatch() {
    func merge(_ patch: String, into target: String) -> JSONValue { JSONMergePatch.apply(jv(patch), to: jv(target)) }
    #expect(merge(#"{"a":"c"}"#, into: #"{"a":"b"}"#) == jv(#"{"a":"c"}"#))
    #expect(merge(#"{"a":null}"#, into: #"{"a":"b","c":"d"}"#) == jv(#"{"c":"d"}"#))
    #expect(merge(#"{"a":{"b":"d","c":null}}"#, into: #"{"a":{"b":"c"}}"#) == jv(#"{"a":{"b":"d"}}"#))
    #expect(merge(#"{"a":[1]}"#, into: #"{"a":[1,2]}"#) == jv(#"{"a":[1]}"#))  // arrays replaced wholesale
    #expect(merge(#"["c"]"#, into: #"{"a":"b"}"#) == jv(#"["c"]"#))  // non-object patch replaces target
    #expect(merge(#"{"b":"c"}"#, into: #"{"a":"a"}"#) == jv(#"{"a":"a","b":"c"}"#))  // adds new key
}

@Test func relativeJSONPointerResolution() throws {
    let doc = jv(#"{"foo":["bar","baz"],"highly":{"nested":{"objects":true}}}"#)
    let base = try JSONPointer("/foo/1")  // currently at "baz"
    #expect(try RelativeJSONPointer("0").resolve(from: base, in: doc) == .string("baz"))
    #expect(try RelativeJSONPointer("1/0").resolve(from: base, in: doc) == .string("bar"))
    #expect(try RelativeJSONPointer("0#").resolve(from: base, in: doc) == .number(1))  // the index of "baz"
    #expect(try RelativeJSONPointer("2/highly/nested").resolve(from: base, in: doc) == jv(#"{"objects":true}"#))
    #expect(try RelativeJSONPointer("0-1").resolve(from: base, in: doc) == .string("bar"))  // index adjust → /foo/0
}

@Test func jsonValueRoundTrips() throws {
    let source = #"{"a":1,"b":[true,null,"x"],"c":{"d":2.5}}"#
    let value = try JSONValue(parsing: source)
    let reparsed = try JSONValue(parsing: value.encoded())
    #expect(reparsed == value)
}
