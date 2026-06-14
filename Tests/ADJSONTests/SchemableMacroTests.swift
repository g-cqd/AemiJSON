import Foundation
import Testing

@testable import ADJSON

@Schemable
private struct SAddr {
    var city: String
    var zip: Int
}

@Schemable
private struct SPerson {
    var name: String
    var age: Int
    var nickname: String?
    var addr: SAddr
    var scores: [Double]
    var labels: [String: Int]
}

private func parsed(_ s: String) -> JSON { try! ADJSON.parse(s).root }

@Test func schemableValidatesMatchingDocument() {
    let json = #"{"name":"Ada","age":30,"addr":{"city":"London","zip":1},"scores":[9.5,8.0],"labels":{"a":1}}"#
    #expect(SPerson.jsonSchema.isValid(parsed(json)))
}

@Test func schemableRejectsMissingRequiredProperty() {
    // `name` is required and absent.
    let json = #"{"age":30,"addr":{"city":"London","zip":1},"scores":[],"labels":{}}"#
    #expect(!SPerson.jsonSchema.isValid(parsed(json)))
}

@Test func schemableEmbedsNestedSchema() {
    // `addr.zip` is typed integer by the embedded SAddr schema, so a string must be rejected —
    // this only fails if the nested @Schemable type's schema was composed into the parent.
    let json = #"{"name":"Ada","age":30,"addr":{"city":"London","zip":"oops"},"scores":[],"labels":{}}"#
    #expect(!SPerson.jsonSchema.isValid(parsed(json)))
}

@Test func schemableTypesArrayItems() {
    let json = #"{"name":"Ada","age":30,"addr":{"city":"L","zip":1},"scores":["x"],"labels":{}}"#
    #expect(!SPerson.jsonSchema.isValid(parsed(json)))
}

@Test func schemableOptionalIsNotRequired() {
    let required = Set(parsed(SPerson.__adjsonSchemaText)["required"].arrayValue.compactMap(\.string))
    #expect(required == ["addr", "age", "labels", "name", "scores"])
}

@Test func schemableMatchesReflectionDescribe() {
    let sample = SPerson(
        name: "Ada", age: 30, nickname: "A", addr: SAddr(city: "London", zip: 1),
        scores: [1.0, 2.0], labels: ["a": 1])
    let viaDescribe = try! JSONSchema(parsing: JSONSchema.describe(sample))
    let doc = parsed(
        #"{"name":"Ada","age":31,"nickname":"B","addr":{"city":"NYC","zip":2},"scores":[3.0],"labels":{"b":2}}"#)
    #expect(SPerson.jsonSchema.isValid(doc))
    #expect(viaDescribe.isValid(doc))
}
