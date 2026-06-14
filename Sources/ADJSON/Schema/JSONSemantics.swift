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
    // Iterative: a work-stack of pairs left to compare replaces structural recursion, so equality
    // of deeply nested values can't overflow the stack. Comparison order doesn't affect the result.
    var stack: [(JSON, JSON)] = [(a, b)]
    while let (x, y) = stack.popLast() {
        if x.isNull {
            if !y.isNull { return false }
        } else if let xb = x.bool {
            if y.bool != xb { return false }
        } else if x.isNumberKind {
            guard y.isNumberKind, let av = x.double, let bv = y.double, av == bv else { return false }
        } else if let xs = x.string {
            if y.string != xs { return false }
        } else if x.isArray {
            guard y.isArray, x.count == y.count, let xe = x.array, let ye = y.array else { return false }
            for i in 0..<xe.count { stack.append((xe[i], ye[i])) }
        } else if x.isObject {
            guard y.isObject, let xo = x.object, let yo = y.object, xo.count == yo.count else { return false }
            for (k, v) in xo {
                guard let yv = yo[k] else { return false }
                stack.append((v, yv))
            }
        } else {
            return false
        }
    }
    return true
}

func jsonPointerEscape(_ s: String) -> String {
    // Most keys contain neither `~` nor `/`, so skip the Foundation `replacingOccurrences` calls
    // (which bridge through NSString) and return the key unchanged.
    guard s.utf8.contains(where: { $0 == 0x7E || $0 == 0x2F }) else { return s }
    return s.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
}
