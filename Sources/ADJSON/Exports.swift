// The umbrella `ADJSON` module layers Foundation interop, Codable, Schema, and the
// macro surface on top of the Foundation-free `ADJSONCore` engine. Re-export the core
// so `import ADJSON` exposes the engine and umbrella types together as one flat public API.
@_exported import ADJSONCore
// `JSONValue.object` is an `OrderedDictionary`, so re-export `OrderedCollections` too: an
// `import ADJSON` consumer can then pattern-match and manipulate `.object` payloads without a
// separate import. (`ADJSONCore`-only consumers import `OrderedCollections` themselves.)
@_exported import OrderedCollections
