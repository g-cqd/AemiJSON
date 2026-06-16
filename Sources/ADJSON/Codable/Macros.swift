/// Generates a high-throughput, monomorphic fast path for a `Codable` `struct` so that
/// `ADJSON.JSONDecoder` / `ADJSON.JSONEncoder` decode/encode it without the generic
/// container overhead. The type keeps its standard `Codable` conformance as a fallback.
///
/// First cut supports `struct`s whose stored properties have explicit type annotations.
/// Types that declare a custom `CodingKeys` are left on the generic path (the fast path
/// would otherwise use the wrong keys).
@attached(
    extension,
    conformances: ADJSONFastDecodable, ADJSONFastEncodable,
    names: named(__adjsonDecode(_:)), named(__adjsonEncode(into:))
)
public macro JSONCodable() = #externalMacro(module: "ADJSONMacros", type: "JSONCodableMacro")

/// Decode-only variant of ``JSONCodable``: generates only the fast `ADJSONFastDecodable` path, so a
/// type that is `Decodable` (but not `Encodable`) — e.g. an LLM/MCP tool input — gets the monomorphic
/// fast decode path without being forced to add an unused `Encodable`/encode conformance.
@attached(extension, conformances: ADJSONFastDecodable, names: named(__adjsonDecode(_:)))
public macro JSONDecodable() = #externalMacro(module: "ADJSONMacros", type: "JSONDecodableMacro")

/// Encode-only variant of ``JSONCodable``: generates only the fast `ADJSONFastEncodable` path, for a
/// type that is `Encodable` (but not `Decodable`).
@attached(extension, conformances: ADJSONFastEncodable, names: named(__adjsonEncode(into:)))
public macro JSONEncodable() = #externalMacro(module: "ADJSONMacros", type: "JSONEncodableMacro")
