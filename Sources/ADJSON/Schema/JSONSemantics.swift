import ADJSONCore
import Foundation

/// JSON Schema instance types.
public enum SchemaType: String, Sendable, CaseIterable {
    case null, boolean, object, array, number, integer, string
}

extension JSON {
    func matchesSchemaType(_ t: SchemaType) -> Bool {
        switch t {
        case .null: return isNull
        case .boolean: return isBoolKind
        case .string: return isStringKind
        case .object: return isObject
        case .array: return isArray
        case .number: return isNumberKind
        case .integer:
            guard isNumberKind, let d = double, d.isFinite else { return false }
            return d.rounded() == d
        }
    }
}

func jsonPointerEscape(_ s: String) -> String {
    // Most keys contain neither `~` nor `/`, so skip the Foundation `replacingOccurrences` calls
    // (which bridge through NSString) and return the key unchanged.
    guard s.utf8.contains(where: { $0 == 0x7E || $0 == 0x2F }) else { return s }
    return s.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
}
