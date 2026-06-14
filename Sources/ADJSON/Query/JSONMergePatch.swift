public import Foundation

/// RFC 7396 JSON Merge Patch. A patch that is an object recursively merges into the
/// target; a member whose patch value is `null` removes that key; a non-object patch
/// replaces the target outright.
public enum JSONMergePatch {
    public static func apply(_ patch: JSONValue, to target: JSONValue) -> JSONValue {
        guard case .object(let patchMembers) = patch else { return patch }
        var result: [String: JSONValue]
        if case .object(let existing) = target { result = existing } else { result = [:] }
        for (key, value) in patchMembers {
            if case .null = value {
                result[key] = nil
            } else {
                result[key] = apply(value, to: result[key] ?? .null)
            }
        }
        return .object(result)
    }

    public static func apply(_ patchData: Data, toData targetData: Data) throws -> Data {
        try apply(try JSONValue(parsing: patchData), to: try JSONValue(parsing: targetData)).encoded()
    }
}
