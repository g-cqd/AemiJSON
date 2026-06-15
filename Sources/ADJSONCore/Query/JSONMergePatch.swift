import OrderedCollections

/// RFC 7396 JSON Merge Patch. A patch that is an object recursively merges into the
/// target; a member whose patch value is `null` removes that key; a non-object patch
/// replaces the target outright.
public enum JSONMergePatch {
    /// Native-recursion cap. The merge recurses once per nested-object level in the *patch*; a
    /// parsed patch is already bounded by the parser's `maxDepth`, but a programmatically-built one
    /// is not, so past this depth we stop merging and let the remaining patch object replace the
    /// target wholesale (bounded, no recursion) rather than overflow the stack. Light frames, so the
    /// cap matches ``JSONValue/maxMutationDepth``.
    static let maxMergeDepth = 256

    public static func apply(_ patch: JSONValue, to target: JSONValue) -> JSONValue {
        apply(patch, to: target, depth: 0)
    }

    private static func apply(_ patch: JSONValue, to target: JSONValue, depth: Int) -> JSONValue {
        guard case .object(let patchMembers) = patch else { return patch }
        // Past the cap, the patch object replaces the target outright (the deep merge degrades to a
        // replace) — pathological depth only, so the semantic difference never reaches real patches.
        guard depth < maxMergeDepth else { return patch }
        var result: OrderedDictionary<String, JSONValue>
        if case .object(let existing) = target { result = existing } else { result = [:] }
        for (key, value) in patchMembers {
            if case .null = value {
                result[key] = nil
            } else {
                result[key] = apply(value, to: result[key] ?? .null, depth: depth + 1)
            }
        }
        return .object(result)
    }
}
