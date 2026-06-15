// SQLite JSON1-dialect functions layered on `SQLiteJSONPath`. Read accessors operate on the lazy
// `JSON` view; mutations produce a new `JSONValue` tree (SQLite's JSON functions are pure — they
// return a modified copy rather than editing in place). Table-valued `json_each`/`json_tree` are
// out of scope (they only make sense inside SQLite). `json_quote` is omitted: it serializes a SQL
// value, which has no ADJSON analogue — use `JSONValue.encoded()`.

// MARK: - Path-relative accessors and mutations (json -> / ->> / set / insert / replace / remove)

extension SQLiteJSONPath {
    /// `json -> path`: the addressed node as a JSON value (a string stays quoted when serialized),
    /// or a missing sentinel when the path doesn't resolve. (`evaluate` under the SQLite name.)
    public func arrow(_ root: JSON) -> JSON { evaluate(root) }

    /// `json ->> path`: the addressed value as unquoted text — a JSON string yields its raw
    /// characters, numbers/booleans yield their literal text, objects/arrays yield their JSON text,
    /// and a missing element or JSON `null` yields `nil` (SQL NULL).
    public func arrowText(_ root: JSON) -> String? {
        let node = evaluate(root)
        guard node.exists, !node.isNull else { return nil }
        if let string = node.string { return string }
        if let bool = node.bool { return bool ? "true" : "false" }
        return (try? JSONValue(node).encodedBytes()).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `json_set`: set the value at the path, overwriting an existing element or creating a new
    /// object key / appended array element (`[#]`). Returns the original tree unchanged when an
    /// intermediate parent is missing or has the wrong kind.
    public func set(_ value: JSONValue, in root: JSONValue) -> JSONValue {
        mutate(root, segments[...], value, .set)
    }

    /// `json_insert`: like `set`, but only *creates* — an element that already exists is left
    /// untouched.
    public func insert(_ value: JSONValue, in root: JSONValue) -> JSONValue {
        mutate(root, segments[...], value, .insert)
    }

    /// `json_replace`: like `set`, but only *overwrites* — a path that doesn't already exist is a
    /// no-op.
    public func replace(_ value: JSONValue, in root: JSONValue) -> JSONValue {
        mutate(root, segments[...], value, .replace)
    }

    /// `json_remove`: remove the addressed element. A path that doesn't resolve is a no-op.
    public func remove(in root: JSONValue) -> JSONValue {
        mutate(root, segments[...], nil, .remove)
    }

    private enum Mode { case set, insert, replace, remove }

    // Recurses over the compiled path's segments (bounded by the path length — a handful — not the
    // document depth), folding the mutation into a fresh copy. Out-of-range indices, missing
    // parents, and kind mismatches are no-ops, matching SQLite's lenient behaviour.
    private func mutate(
        _ node: JSONValue, _ segs: ArraySlice<Segment>, _ value: JSONValue?, _ mode: Mode
    )
        -> JSONValue
    {
        guard let segment = segs.first else {
            switch mode {
            case .set, .replace: return value ?? node
            case .insert: return node  // the root already exists
            case .remove: return .null  // removing the whole document
            }
        }
        let rest = segs.dropFirst()
        switch segment {
        case .key(let key):
            guard case .object(var members) = node else { return node }
            if rest.isEmpty {
                let exists = members[key] != nil
                switch mode {
                case .set: members[key] = value
                case .insert: if !exists { members[key] = value }
                case .replace: if exists { members[key] = value }
                case .remove: members[key] = nil
                }
            } else {
                guard let child = members[key] else { return node }
                members[key] = mutate(child, rest, value, mode)
            }
            return .object(members)

        case .index(let index):
            return mutateArrayElement(node, at: index, rest, value, mode)

        case .fromEnd(let n):
            guard case .array(let elements) = node else { return node }
            return mutateArrayElement(node, at: elements.count - n, rest, value, mode)

        case .append:
            guard case .array(var elements) = node, rest.isEmpty else { return node }
            if mode == .set || mode == .insert, let value { elements.append(value) }
            return .array(elements)
        }
    }

    private func mutateArrayElement(
        _ node: JSONValue, at index: Int, _ rest: ArraySlice<Segment>, _ value: JSONValue?, _ mode: Mode
    ) -> JSONValue {
        guard case .array(var elements) = node, index >= 0, index < elements.count else { return node }
        if rest.isEmpty {
            switch mode {
            case .set, .replace: if let value { elements[index] = value }
            case .insert: break  // the element already exists
            case .remove: elements.remove(at: index)
            }
        } else {
            elements[index] = mutate(elements[index], rest, value, mode)
        }
        return .array(elements)
    }
}

// MARK: - Document-level functions (json_type / json_array_length / json_valid / json_extract / json_patch)

public enum SQLiteJSON {
    /// `json_type(X)`: the SQLite type name of `json` — `"object"`, `"array"`, `"integer"`,
    /// `"real"`, `"true"`, `"false"`, `"null"`, or `"text"` — or `nil` if the value is missing.
    public static func type(_ json: JSON) -> String? {
        guard json.exists else { return nil }
        if json.isObject { return "object" }
        if json.isArray { return "array" }
        if json.isNull { return "null" }
        if let bool = json.bool { return bool ? "true" : "false" }
        if json.isNumberKind { return json.int != nil ? "integer" : "real" }
        if json.isStringKind { return "text" }
        return nil
    }

    /// `json_array_length(X)`: the number of elements in `json`, or 0 when it is not an array.
    public static func arrayLength(_ json: JSON) -> Int { json.isArray ? json.count : 0 }

    /// `json_valid(X)`: whether the bytes parse as RFC 8259 JSON.
    public static func valid(_ bytes: [UInt8]) -> Bool { (try? ADJSON.parse(bytes)) != nil }

    /// `json_valid(X)`: whether the string parses as RFC 8259 JSON.
    public static func valid(_ string: String) -> Bool { (try? ADJSON.parse(string)) != nil }

    /// `json_extract(X, P1, …)`: a single path returns the addressed value (or `null` when missing);
    /// multiple paths return a JSON array of the addressed values (missing elements become `null`).
    public static func extract(_ root: JSON, _ paths: [SQLiteJSONPath]) -> JSONValue {
        func value(_ path: SQLiteJSONPath) -> JSONValue {
            let node = path.evaluate(root)
            return node.exists ? JSONValue(node) : .null
        }
        if paths.count == 1 { return value(paths[0]) }
        return .array(paths.map(value))
    }

    /// `json_patch(T, P)`: apply the RFC 7396 merge patch `patch` to `target`.
    public static func patch(_ target: JSONValue, with patch: JSONValue) -> JSONValue {
        JSONMergePatch.apply(patch, to: target)
    }
}
