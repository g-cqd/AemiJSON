import ADJSONCore
#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

// Accumulates observed shape across samples. `required` = keys present in every
// object sample; arrays merge their element shapes; integer is widened to number
// if any non-integral value is seen.
final class SchemaAccumulator {
    var types = Set<String>()
    var properties: [String: SchemaAccumulator] = [:]
    var presence: [String: Int] = [:]
    var objectCount = 0
    var items: SchemaAccumulator?
}

// Cap on how deep an inferred accumulator can get. `ingest`/`render` are iterative (explicit heap
// stacks), so they can't overflow the native stack at any input depth; this bounds the accumulator's
// size and the depth of its (necessarily recursive) ARC deallocation, so a pathologically deep,
// untrusted sample can't exhaust memory or the stack on teardown. Past it a level keeps its type but
// not its nested shape. `describeValue` (the trusted-reflection path) is recursive and honors the same cap.
private let maxInferenceDepth = 256

// Iterative (explicit-stack) shape accumulation: a deeply nested, untrusted sample is walked without
// native-stack recursion. Visitation order doesn't affect the result — every step only inserts types
// or bumps counts into shared accumulators — so the reverse (LIFO) order is equivalent.
private func ingest(_ root: JSON, into rootAcc: SchemaAccumulator) {
    var stack: [(JSON, SchemaAccumulator, Int)] = [(root, rootAcc, 0)]
    while let (j, acc, depth) = stack.popLast() {
        if j.isNull {
            acc.types.insert("null")
        } else if j.bool != nil {
            acc.types.insert("boolean")
        } else if j.isNumberKind {
            // Instance-based inference can't distinguish `2` from `2.0` — both are just JSON numbers —
            // so a whole-valued sample is inferred as `integer`. If any later sample is non-integral the
            // type widens to `number` (see `render`, which drops `integer` when `number` is also
            // present). The `@Schemable` macro path (`describeValue`) instead reads the *static* Swift
            // type, so a `Double` property is correctly `number` even when its value happens to be whole.
            if let d = j.double, d.isFinite, d.rounded() == d {
                acc.types.insert("integer")
            } else {
                acc.types.insert("number")
            }
        } else if j.string != nil {
            acc.types.insert("string")
        } else if j.isArray {
            acc.types.insert("array")
            guard depth < maxInferenceDepth else { continue }
            let items = acc.items ?? SchemaAccumulator()
            acc.items = items
            for e in j.arrayValue { stack.append((e, items, depth + 1)) }
        } else if j.isObject {
            acc.types.insert("object")
            acc.objectCount += 1
            guard depth < maxInferenceDepth else { continue }
            for (k, v) in j.objectValue {
                let sub = acc.properties[k] ?? SchemaAccumulator()
                acc.properties[k] = sub
                acc.presence[k, default: 0] += 1
                stack.append((v, sub, depth + 1))
            }
        }
    }
}

private func describeValue(_ value: Any, into acc: SchemaAccumulator, depth: Int = 0) {
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
        case .optional:
            if let child = mirror.children.first {
                describeValue(child.value, into: acc, depth: depth + 1)
            } else {
                acc.types.insert("null")
            }
        case .struct, .class:
            acc.types.insert("object")
            acc.objectCount += 1
            guard depth < maxInferenceDepth else { return }
            for child in mirror.children {
                guard let label = child.label else { continue }
                let sub = acc.properties[label] ?? SchemaAccumulator()
                describeValue(child.value, into: sub, depth: depth + 1)
                acc.properties[label] = sub
                if Mirror(reflecting: child.value).displayStyle != .optional { acc.presence[label, default: 0] += 1 }
            }
        case .collection:
            acc.types.insert("array")
            guard depth < maxInferenceDepth else { return }
            let items = acc.items ?? SchemaAccumulator()
            for child in mirror.children { describeValue(child.value, into: items, depth: depth + 1) }
            acc.items = items
        case .dictionary:
            acc.types.insert("object")
        default:
            switch value {
                case is Bool: acc.types.insert("boolean")
                case is Int, is Int8, is Int16, is Int32, is Int64, is UInt, is UInt8, is UInt16, is UInt32, is UInt64:
                    acc.types.insert("integer")
                case is Double, is Float: acc.types.insert("number")
                case is String: acc.types.insert("string")
                default: break
            }
    }
}

// Iterative post-order render: each accumulator is assembled from its already-rendered children, so a
// deep accumulator serializes without native-stack recursion. The accumulator tree is acyclic (every
// `items` / property is a distinct node), so each node is rendered exactly once.
private func render(_ root: SchemaAccumulator) -> String {
    var done: [ObjectIdentifier: String] = [:]
    var work: [(SchemaAccumulator, Bool)] = [(root, false)]
    while let (acc, expanded) = work.popLast() {
        let id = ObjectIdentifier(acc)
        if done[id] != nil { continue }
        if expanded {
            done[id] = renderNode(acc, children: done)
        } else {
            work.append((acc, true))  // re-visit after its children are rendered
            if acc.types.contains("object") {
                for (_, sub) in acc.properties { work.append((sub, false)) }
            }
            if acc.types.contains("array"), let items = acc.items { work.append((items, false)) }
        }
    }
    return done[ObjectIdentifier(root)] ?? "{}"
}

// Assemble one node's schema text from its already-rendered children — each child is looked up by
// its cached rendering, so a node composes its JSON from finished parts without recursing.
private func renderNode(_ acc: SchemaAccumulator, children: [ObjectIdentifier: String]) -> String {
    var parts: [String] = []
    var types = acc.types
    if types.contains("number") { types.remove("integer") }
    if types.count == 1, let only = types.first {
        parts.append("\"type\":\(schemaQuote(only))")
    } else if !types.isEmpty {
        parts.append("\"type\":[\(types.sorted().map(schemaQuote).joined(separator: ","))]")
    }
    if acc.types.contains("object"), !acc.properties.isEmpty {
        let props = acc.properties.sorted { $0.key < $1.key }
            .map { "\(schemaQuote($0.key)):\(children[ObjectIdentifier($0.value)] ?? "{}")" }
            .joined(separator: ",")
        parts.append("\"properties\":{\(props)}")
        let required = acc.properties.keys.filter { acc.presence[$0] == acc.objectCount && acc.objectCount > 0 }
            .sorted()
        if !required.isEmpty {
            parts.append("\"required\":[\(required.map(schemaQuote).joined(separator: ","))]")
        }
    }
    if acc.types.contains("array"), let items = acc.items {
        parts.append("\"items\":\(children[ObjectIdentifier(items)] ?? "{}")")
    }
    return "{\(parts.joined(separator: ","))}"
}

// Reuses the canonical encoder escaper (the single source of truth in `JSONOutput`) so the
// rendered schema text escapes control characters identically to the rest of the library.
private func schemaQuote(_ s: String) -> String {
    var out: [UInt8] = []
    JSONOutput.appendString(s, to: &out)
    return String(decoding: out, as: UTF8.self)
}

extension JSONSchema {
    /// Infer a JSON Schema (as schema JSON text) from one or more instance samples.
    public static func infer(from samples: [JSON]) -> String {
        let acc = SchemaAccumulator()
        for s in samples { ingest(s, into: acc) }
        return render(acc)
    }

    public static func infer(fromJSONTexts texts: [String]) throws -> String {
        infer(from: try texts.map { try ADJSON.parse($0).root })
    }

    /// Generate a JSON Schema (as schema JSON text) from a Swift value via reflection.
    /// Optional properties become non-required; nested structs/arrays recurse.
    /// For compile-time, instance-free generation from a type alone, use the `@Schemable` macro,
    /// which conforms the type to ``ADJSONSchemaProviding`` and provides `T.jsonSchema`.
    public static func describe(_ instance: Any) -> String {
        let acc = SchemaAccumulator()
        describeValue(instance, into: acc)
        return render(acc)
    }

    /// Compile a schema inferred from samples.
    public static func inferred(from samples: [JSON]) throws -> JSONSchema {
        try JSONSchema(parsing: infer(from: samples))
    }
}
