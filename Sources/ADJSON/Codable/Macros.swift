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
