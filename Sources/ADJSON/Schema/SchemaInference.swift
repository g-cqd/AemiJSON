import Foundation

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

private func ingest(_ j: JSON, into acc: SchemaAccumulator) {
    if j.isNull {
        acc.types.insert("null")
    } else if j.bool != nil {
        acc.types.insert("boolean")
    } else if j.isNumberKind {
        if let d = j.double, d.isFinite, d.rounded() == d {
            acc.types.insert("integer")
        } else {
            acc.types.insert("number")
        }
    } else if j.string != nil {
        acc.types.insert("string")
    } else if j.isArray {
        acc.types.insert("array")
        let items = acc.items ?? SchemaAccumulator()
        for e in j.arrayValue { ingest(e, into: items) }
        acc.items = items
    } else if j.isObject {
        acc.types.insert("object")
        acc.objectCount += 1
        for (k, v) in j.objectValue {
            let sub = acc.properties[k] ?? SchemaAccumulator()
            ingest(v, into: sub)
            acc.properties[k] = sub
            acc.presence[k, default: 0] += 1
        }
    }
}

private func describeValue(_ value: Any, into acc: SchemaAccumulator) {
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .optional:
        if let child = mirror.children.first { describeValue(child.value, into: acc) } else { acc.types.insert("null") }
    case .struct, .class:
        acc.types.insert("object")
        acc.objectCount += 1
        for child in mirror.children {
            guard let label = child.label else { continue }
            let sub = acc.properties[label] ?? SchemaAccumulator()
            describeValue(child.value, into: sub)
            acc.properties[label] = sub
            if Mirror(reflecting: child.value).displayStyle != .optional { acc.presence[label, default: 0] += 1 }
        }
    case .collection:
        acc.types.insert("array")
        let items = acc.items ?? SchemaAccumulator()
        for child in mirror.children { describeValue(child.value, into: items) }
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

private func render(_ acc: SchemaAccumulator) -> String {
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
            .map { "\(schemaQuote($0.key)):\(render($0.value))" }
            .joined(separator: ",")
        parts.append("\"properties\":{\(props)}")
        let required = acc.properties.keys.filter { acc.presence[$0] == acc.objectCount && acc.objectCount > 0 }
            .sorted()
        if !required.isEmpty {
            parts.append("\"required\":[\(required.map(schemaQuote).joined(separator: ","))]")
        }
    }
    if acc.types.contains("array"), let items = acc.items {
        parts.append("\"items\":\(render(items))")
    }
    return "{\(parts.joined(separator: ","))}"
}

private func schemaQuote(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default: out.unicodeScalars.append(ch)
        }
    }
    out += "\""
    return out
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
    /// (A `@Schemable` macro would enable type-based generation without an instance.)
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
