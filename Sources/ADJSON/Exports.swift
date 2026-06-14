// The umbrella `ADJSON` module layers Foundation interop, Codable, Schema, and the
// macro surface on top of the dependency-free `ADJSONCore` engine. Re-export the core
// so existing `import ADJSON` consumers see the same flat public API as before the split.
@_exported import ADJSONCore
