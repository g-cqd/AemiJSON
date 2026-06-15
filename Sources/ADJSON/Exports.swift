// The umbrella `ADJSON` module layers Foundation interop, Codable, Schema, and the
// macro surface on top of the Foundation-free `ADJSONCore` engine. Re-export the core
// so existing `import ADJSON` consumers see the same flat public API as before the split.
@_exported import ADJSONCore
// `JSONValue.object` is an `OrderedDictionary`, so re-export `OrderedCollections` too: an
// `import ADJSON` consumer can then pattern-match and manipulate `.object` payloads without a
// separate import. (`ADJSONCore`-only consumers import `OrderedCollections` themselves.)
@_exported import OrderedCollections
