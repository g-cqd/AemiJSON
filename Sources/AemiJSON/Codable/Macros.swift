/// Generates a high-throughput, monomorphic fast path for a `Codable` `struct` so that
/// `AemiJSON.JSONDecoder` / `AemiJSON.JSONEncoder` decode/encode it without the generic
/// container overhead. The type keeps its standard `Codable` conformance as a fallback.
///
/// First cut supports `struct`s whose stored properties have explicit type annotations.
/// Types that declare a custom `CodingKeys` are left on the generic path (the fast path
/// would otherwise use the wrong keys).
@attached(
    extension,
    conformances: AemiJSONFastDecodable, AemiJSONFastEncodable,
    names: named(__adjsonDecode(_:)), named(__adjsonEncode(into:))
)
public macro JSONCodable() = #externalMacro(module: "AemiJSONMacros", type: "JSONCodableMacro")

/// Decode-only variant of ``JSONCodable()``: generates only the fast `AemiJSONFastDecodable` path, so a
/// type that is `Decodable` (but not `Encodable`) — e.g. an LLM/MCP tool input — gets the monomorphic
/// fast decode path without being forced to add an unused `Encodable`/encode conformance.
@attached(extension, conformances: AemiJSONFastDecodable, names: named(__adjsonDecode(_:)))
public macro JSONDecodable() = #externalMacro(module: "AemiJSONMacros", type: "JSONDecodableMacro")

/// Encode-only variant of ``JSONCodable()``: generates only the fast `AemiJSONFastEncodable` path, for a
/// type that is `Encodable` (but not `Decodable`).
@attached(extension, conformances: AemiJSONFastEncodable, names: named(__adjsonEncode(into:)))
public macro JSONEncodable() = #externalMacro(module: "AemiJSONMacros", type: "JSONEncodableMacro")
