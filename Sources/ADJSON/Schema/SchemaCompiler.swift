import Foundation

// Compiles a schema JSON document into a flat `[SchemaNode]` table. Each subschema gets an index;
// recursive references are indices. The registry maps each subschema's JSON-Pointer-from-root to
// its index (for local `$ref` resolution).
final class SchemaCompiler {
    var nodes: [SchemaNode] = []
    var registry: [String: Int] = [:]
    private var work: [(schema: JSON, path: String, index: Int)] = []

    // Iterative: reserve the root index, then drain a work-stack of subschemas. Reserving an index
    // and registering its path *before* filling means the parent stores child indices without
    // waiting for them, so deeply nested schemas compile without recursion (no stack overflow). The
    // absolute index values differ from a recursive compile, but every reference stays consistent —
    // validation results are identical.
    @discardableResult
    func compile(_ schema: JSON, at path: String) -> Int {
        let root = reserve(schema, at: path)
        while let item = work.popLast() {
            var node = SchemaNode()
            if let b = item.schema.bool {
                node.boolean = b
            } else if !item.schema.isObject {
                node.boolean = true  // non-object, non-boolean → accept everything
            } else {
                fill(&node, from: item.schema, at: item.path)
            }
            nodes[item.index] = node
        }
        return root
    }

    // Reserve a node slot + register its path, and defer the fill to the work-stack.
    @discardableResult
    private func reserve(_ schema: JSON, at path: String) -> Int {
        let index = nodes.count
        nodes.append(SchemaNode())  // placeholder, patched when drained
        registry[path] = index
        work.append((schema, path, index))
        return index
    }

    private func fill(_ node: inout SchemaNode, from schema: JSON, at path: String) {
        if let s = schema["type"].string, let t = SchemaType(rawValue: s) {
            node.types = [t]
        } else if let arr = schema["type"].array {
            node.types = arr.compactMap { $0.string.flatMap(SchemaType.init(rawValue:)) }
        }

        if schema["const"].exists { node.constValue = schema["const"] }
        if let e = schema["enum"].array { node.enumValues = e }

        node.minimum = schema["minimum"].double
        node.maximum = schema["maximum"].double
        node.exclusiveMinimum = schema["exclusiveMinimum"].double
        node.exclusiveMaximum = schema["exclusiveMaximum"].double
        node.multipleOf = schema["multipleOf"].double

        node.minLength = schema["minLength"].int
        node.maxLength = schema["maxLength"].int
        if let p = schema["pattern"].string { node.pattern = SendableRegex(p) }

        node.minItems = schema["minItems"].int
        node.maxItems = schema["maxItems"].int
        node.uniqueItems = schema["uniqueItems"].bool ?? false

        node.minProperties = schema["minProperties"].int
        node.maxProperties = schema["maxProperties"].int
        if let r = schema["required"].array { node.required = r.compactMap(\.string) }

        if let props = schema["properties"].object {
            var d = [String: Int]()
            for (k, v) in props { d[k] = reserve(v, at: path + "/properties/" + jsonPointerEscape(k)) }
            node.properties = d
        }
        if let pp = schema["patternProperties"].object {
            var list = [(SendableRegex, Int)]()
            for (k, v) in pp {
                if let re = SendableRegex(k) {
                    list.append((re, reserve(v, at: path + "/patternProperties/" + jsonPointerEscape(k))))
                }
            }
            node.patternProperties = list
        }
        if schema["additionalProperties"].exists {
            node.additionalProperties = reserve(schema["additionalProperties"], at: path + "/additionalProperties")
        }

        if let pi = schema["prefixItems"].array {
            node.prefixItems = pi.enumerated().map { reserve($1, at: path + "/prefixItems/\($0)") }
        }
        if schema["items"].exists {
            node.items = reserve(schema["items"], at: path + "/items")
        }
        if schema["contains"].exists {
            node.contains = reserve(schema["contains"], at: path + "/contains")
            node.minContains = schema["minContains"].int
            node.maxContains = schema["maxContains"].int
        }

        if let a = schema["allOf"].array { node.allOf = a.enumerated().map { reserve($1, at: path + "/allOf/\($0)") } }
        if let a = schema["anyOf"].array { node.anyOf = a.enumerated().map { reserve($1, at: path + "/anyOf/\($0)") } }
        if let a = schema["oneOf"].array { node.oneOf = a.enumerated().map { reserve($1, at: path + "/oneOf/\($0)") } }
        if schema["not"].exists { node.not = reserve(schema["not"], at: path + "/not") }

        if schema["if"].exists { node.ifSchema = reserve(schema["if"], at: path + "/if") }
        if schema["then"].exists { node.thenSchema = reserve(schema["then"], at: path + "/then") }
        if schema["else"].exists { node.elseSchema = reserve(schema["else"], at: path + "/else") }

        if let dr = schema["dependentRequired"].object {
            var d = [String: [String]]()
            for (k, v) in dr { d[k] = (v.array ?? []).compactMap(\.string) }
            node.dependentRequired = d
        }
        if let ds = schema["dependentSchemas"].object {
            var d = [String: Int]()
            for (k, v) in ds { d[k] = reserve(v, at: path + "/dependentSchemas/" + jsonPointerEscape(k)) }
            node.dependentSchemas = d
        }

        if let defs = schema["$defs"].object {
            for (k, v) in defs { reserve(v, at: path + "/$defs/" + jsonPointerEscape(k)) }
        }

        if let r = schema["$ref"].string { node.ref = r }
    }
}
