import OrderedCollections

// SQLite JSON1-dialect functions layered on `SQLiteJSONPath`. Read accessors operate on the lazy
// `JSON` view; mutations produce a new `JSONValue` tree (SQLite's JSON functions are pure — they
// return a modified copy rather than editing in place). The table-valued `json_each` / `json_tree`
// are surfaced as Swift `Sequence`s over the lazy view (their natural shape outside a SQL engine),
// and `json_quote` serializes a value to JSON text.

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

    // Native-recursion cap. `mutate` recurses once per compiled path segment; a path parsed from a
    // string is short, but the public API also accepts a programmatically-built path, so past this
    // depth the mutation is a no-op (returns the node unchanged) — matching SQLite's lenient
    // "bad input → no-op" behaviour — rather than overflowing the stack. Matches the other
    // value-mutation caps (light frames).
    private static let maxMutateDepth = 256

    // Recurses over the compiled path's segments (bounded by the path length — a handful — not the
    // document depth), folding the mutation into a fresh copy. Out-of-range indices, missing
    // parents, and kind mismatches are no-ops, matching SQLite's lenient behaviour.
    private func mutate(
        _ node: JSONValue, _ segs: ArraySlice<Segment>, _ value: JSONValue?, _ mode: Mode, _ depth: Int = 0
    )
        -> JSONValue
    {
        guard depth < Self.maxMutateDepth else { return node }
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
                members[key] = mutate(child, rest, value, mode, depth + 1)
            }
            return .object(members)

        case .index(let index):
            return mutateArrayElement(node, at: index, rest, value, mode, depth)

        case .fromEnd(let n):
            guard case .array(let elements) = node else { return node }
            return mutateArrayElement(node, at: elements.count - n, rest, value, mode, depth)

        case .append:
            guard case .array(var elements) = node, rest.isEmpty else { return node }
            if mode == .set || mode == .insert, let value { elements.append(value) }
            return .array(elements)
        }
    }

    private func mutateArrayElement(
        _ node: JSONValue, at index: Int, _ rest: ArraySlice<Segment>, _ value: JSONValue?, _ mode: Mode, _ depth: Int
    ) -> JSONValue {
        guard case .array(var elements) = node, index >= 0, index < elements.count else { return node }
        if rest.isEmpty {
            switch mode {
            case .set, .replace: if let value { elements[index] = value }
            case .insert: break  // the element already exists
            case .remove: elements.remove(at: index)
            }
        } else {
            elements[index] = mutate(elements[index], rest, value, mode, depth + 1)
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

    /// `json_quote(X)`: the JSON text of a value — a string is quoted and escaped, numbers /
    /// booleans / null render as their literals, and an object/array as compact JSON. A non-finite
    /// number (only reachable in a hand-built tree) renders as `null`, so the result is always
    /// well-formed JSON.
    public static func quote(_ value: JSONValue) -> String {
        let bytes = (try? value.encodedBytes()) ?? Array("null".utf8)
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Table-valued json_each / json_tree

/// One row of `json_each` / `json_tree`: the SQLite columns reshaped for Swift. `key` is set for an
/// object member, `index` for an array element (both `nil` for the walked value itself); `value` is
/// the lazy node, `type` its ``SQLiteJSON/type(_:)`` name, and `path` the full SQLite-style path to
/// it (re-parseable by ``SQLiteJSONPath``).
public struct SQLiteJSONRow: Sendable {
    public let key: String?
    public let index: Int?
    public let value: JSON
    public let type: String
    public let path: String
}

extension SQLiteJSON {
    /// `json_each(X)`: a sequence over the *immediate* children of `json` — each array element or
    /// object member. A scalar (or `null`) yields a single row for the value itself at path `$`; an
    /// empty container or a missing node yields nothing.
    public static func each(_ root: JSON) -> JSONEachSequence {
        var rows: [SQLiteJSONRow] = []
        if root.isArray {
            var idx = 0
            root.forEachElement { child in
                rows.append(
                    SQLiteJSONRow(
                        key: nil, index: idx, value: child, type: type(child) ?? "null", path: "$[\(idx)]"))
                idx += 1
            }
        } else if root.isObject {
            root.forEachMember { key, child in
                rows.append(
                    SQLiteJSONRow(
                        key: key, index: nil, value: child, type: type(child) ?? "null",
                        path: "$" + pathKeySegment(key)))
            }
        } else if root.exists {
            rows.append(SQLiteJSONRow(key: nil, index: nil, value: root, type: type(root) ?? "null", path: "$"))
        }
        return JSONEachSequence(rows: rows)
    }

    /// `json_tree(X)`: a preorder sequence over `json` *and all its descendants*, root first. The
    /// walk is iterative (an explicit stack, like ``JSONPath`` descent), so an arbitrarily deep
    /// document streams without recursion. A missing node yields nothing.
    public static func tree(_ root: JSON) -> JSONTreeSequence { JSONTreeSequence(root: root) }

    // A SQLite-style object-key path segment: `.label` for a simple identifier, else a JSON-escaped
    // `."label"`. Both forms re-parse through `SQLiteJSONPath`, so a row's `path` round-trips back
    // through `json_extract`.
    static func pathKeySegment(_ key: String) -> String {
        if isSimpleLabel(key) { return "." + key }
        var bytes: [UInt8] = [0x2E]  // '.'
        JSONOutput.appendString(key, to: &bytes)  // "...": quoted + escaped
        return String(decoding: bytes, as: UTF8.self)
    }

    // A label is "simple" (needs no quoting) when it is a non-empty ASCII identifier:
    // `[A-Za-z_][A-Za-z0-9_]*`. Conservative — anything else is quoted, which still round-trips.
    static func isSimpleLabel(_ key: String) -> Bool {
        let utf8 = key.utf8
        guard let first = utf8.first, isLabelStart(first) else { return false }
        return utf8.dropFirst().allSatisfy { isLabelStart($0) || ($0 >= 0x30 && $0 <= 0x39) }
    }

    private static func isLabelStart(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
    }
}

/// The `Sequence` returned by ``SQLiteJSON/each(_:)``. Rows are computed once (one level deep).
public struct JSONEachSequence: Sequence, Sendable {
    let rows: [SQLiteJSONRow]
    public func makeIterator() -> IndexingIterator<[SQLiteJSONRow]> { rows.makeIterator() }
}

/// The `Sequence` returned by ``SQLiteJSON/tree(_:)``: a lazy, iterative preorder walk that never
/// recurses, so it is safe over arbitrarily deep documents.
public struct JSONTreeSequence: Sequence, Sendable {
    let root: JSON

    public func makeIterator() -> Iterator { Iterator(root: root) }

    public struct Iterator: IteratorProtocol {
        // A work stack of rows still to emit. Popping yields preorder (root, then each child's whole
        // subtree); children are pushed reversed so they pop back in document order.
        private var stack: [SQLiteJSONRow]

        init(root: JSON) {
            stack =
                root.exists
                ? [SQLiteJSONRow(key: nil, index: nil, value: root, type: SQLiteJSON.type(root) ?? "null", path: "$")]
                : []
        }

        public mutating func next() -> SQLiteJSONRow? {
            guard let row = stack.popLast() else { return nil }
            let node = row.value
            if node.isArray {
                var kids: [SQLiteJSONRow] = []
                var idx = 0
                node.forEachElement { child in
                    kids.append(
                        SQLiteJSONRow(
                            key: nil, index: idx, value: child, type: SQLiteJSON.type(child) ?? "null",
                            path: row.path + "[\(idx)]"))
                    idx += 1
                }
                stack.append(contentsOf: kids.reversed())
            } else if node.isObject {
                var kids: [SQLiteJSONRow] = []
                node.forEachMember { key, child in
                    kids.append(
                        SQLiteJSONRow(
                            key: key, index: nil, value: child, type: SQLiteJSON.type(child) ?? "null",
                            path: row.path + SQLiteJSON.pathKeySegment(key)))
                }
                stack.append(contentsOf: kids.reversed())
            }
            return row
        }
    }
}
