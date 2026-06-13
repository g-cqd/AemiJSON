import Foundation
import Testing

@testable import ADJSON

@Test func infersSchemaFromSamplesWithRequiredIntersection() throws {
    let samples = [
        #"{"id":1,"name":"a"}"#,
        #"{"id":2,"tag":"x"}"#,
        #"{"id":3,"name":"b"}"#,
    ].map { try! ADJSON.parse($0).root }

    let text = JSONSchema.infer(from: samples)
    let s = try ADJSON.parse(text).root
    #expect(s["type"].string == "object")
    #expect(s["required"].arrayValue.compactMap(\.string) == ["id"])  // present in all samples
    #expect(s["properties"]["id"]["type"].string == "integer")

    let compiled = try JSONSchema(parsing: text)
    #expect(compiled.isValid(try ADJSON.parse(#"{"id":9,"name":"z"}"#).root))
    #expect(!compiled.isValid(try ADJSON.parse(#"{"name":"z"}"#).root))  // missing required id
    #expect(!compiled.isValid(try ADJSON.parse(#"{"id":"nope"}"#).root))  // id must be integer
}

@Test func infersWidenedNumberType() throws {
    let samples = [#"[1,2,3]"#, #"[1.5]"#].map { try! ADJSON.parse($0).root }
    let s = try ADJSON.parse(JSONSchema.infer(from: samples)).root
    #expect(s["type"].string == "array")
    #expect(s["items"]["type"].string == "number")  // integer widened to number
}

@Test func generatesSchemaFromModelViaReflection() throws {
    struct Addr: Codable {
        var city: String
        var zip: Int
    }
    struct Person: Codable {
        var name: String
        var age: Int
        var nickname: String?
        var addr: Addr
        var scores: [Double]
    }

    let text = JSONSchema.describe(
        Person(name: "A", age: 30, nickname: nil, addr: Addr(city: "X", zip: 1), scores: [1.5, 2.0]))
    let s = try ADJSON.parse(text).root

    #expect(s["type"].string == "object")
    #expect(s["properties"]["name"]["type"].string == "string")
    #expect(s["properties"]["age"]["type"].string == "integer")
    #expect(s["properties"]["addr"]["type"].string == "object")
    #expect(s["properties"]["addr"]["properties"]["zip"]["type"].string == "integer")
    #expect(s["properties"]["scores"]["type"].string == "array")

    let required = Set(s["required"].arrayValue.compactMap(\.string))
    #expect(required.isSuperset(of: ["name", "age", "addr", "scores"]))
    #expect(!required.contains("nickname"))  // optional → not required
}
