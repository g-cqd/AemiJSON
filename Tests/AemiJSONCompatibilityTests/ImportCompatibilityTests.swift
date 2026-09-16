import ADJSON
import ADJSONCore
import AemiJSON
import AemiJSONCore
import Testing

@Suite
struct ImportCompatibilityTests {
    @Test
    func `new and compatibility namespaces parse the same document types`() throws {
        let modern: JSONDocument = try AemiJSON.parse("{\"value\":42}")
        let legacy: JSONDocument = try ADJSON.parse("{\"value\":42}")
        #expect(modern.root.value.int == 42)
        #expect(legacy.root.value.int == modern.root.value.int)
    }

    @Test
    func `compatibility codecs decode values produced by the renamed module`() throws {
        let type: any ADJSONFastDecodable.Type = CompatibilityPayload.self
        #expect(ObjectIdentifier(type) == ObjectIdentifier(CompatibilityPayload.self))
        let bytes = try AemiJSON.JSONEncoder().encode(CompatibilityPayload(value: 42))
        let value = try ADJSON.JSONDecoder().decode(CompatibilityPayload.self, from: bytes)
        #expect(value.value == 42)
    }
}

@JSONCodable
private struct CompatibilityPayload: Codable {
    var value: Int
}
