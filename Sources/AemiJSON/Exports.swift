// The umbrella `AemiJSON` module layers Foundation interop, Codable, Schema, and the
// macro surface on top of the Foundation-free `AemiJSONCore` engine. Re-export the core
// so `import AemiJSON` exposes the engine and umbrella types together as one flat public API.
@_exported import AemiJSONCore
// `JSONValue.object` is an `OrderedDictionary`, so re-export `OrderedCollections` too: an
// `import AemiJSON` consumer can then pattern-match and manipulate `.object` payloads without a
// separate import. (`AemiJSONCore`-only consumers import `OrderedCollections` themselves.)
@_exported import OrderedCollections
