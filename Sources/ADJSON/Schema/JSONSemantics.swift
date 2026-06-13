import Foundation

/// JSON Schema instance types.
public enum SchemaType: String, Sendable, CaseIterable {
    case null, boolean, object, array, number, integer, string
}

extension JSON {
    var isNumberKind: Bool { tag == JSONKind.number.rawValue }
    var isBoolKind: Bool { tag == JSONKind.boolTrue.rawValue || tag == JSONKind.boolFalse.rawValue }

    func matchesSchemaType(_ t: SchemaType) -> Bool {
        switch t {
        case .null: return isNull
        case .boolean: return isBoolKind
        case .string: return tag == JSONKind.string.rawValue
        case .object: return isObject
        case .array: return isArray
        case .number: return isNumberKind
        case .integer:
            guard isNumberKind, let d = double, d.isFinite else { return false }
            return d.rounded() == d
        }
    }
}

/// Structural equality used by `const`, `enum`, and `uniqueItems`. Numerically,
/// 1 and 1.0 compare equal (JSON Schema value equality). Works across documents.
func jsonSemanticEqual(_ a: JSON, _ b: JSON) -> Bool {
    if a.isNull { return b.isNull }
    if let x = a.bool { return b.bool == x }
    if a.isNumberKind {
        guard b.isNumberKind, let av = a.double, let bv = b.double else { return false }
        return av == bv
    }
    if let x = a.string { return b.string == x }
    if a.isArray {
        guard b.isArray, a.count == b.count, let ae = a.array, let be = b.array else { return false }
        for i in 0..<ae.count where !jsonSemanticEqual(ae[i], be[i]) { return false }
        return true
    }
    if a.isObject {
        guard b.isObject, let ao = a.object, let bo = b.object, ao.count == bo.count else { return false }
        for (k, v) in ao {
            guard let bv = bo[k], jsonSemanticEqual(v, bv) else { return false }
        }
        return true
    }
    return false
}

func jsonPointerEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
}
