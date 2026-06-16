import OrderedCollections

// SQLite-dialect tree mutation: json_set / json_insert / json_replace / json_remove keyed by a
// `SQLiteJSONPath`, mirroring the read-side `SQLiteJSONPath.evaluate`. Total and non-throwing — an
// unresolvable or wrong-typed path is a no-op (the value is returned unchanged), exactly as SQLite's
// json_* functions behave. Recursion is bounded by `maxMutationDepth` (shared with the RFC-6902
// pointer mutation); past it the operation fails closed to a no-op rather than overflowing the stack.
extension JSONValue {
    /// How ``setting(_:to:mode:)`` resolves a path that may or may not already exist.
    public enum SQLiteSetMode: Sendable, Equatable {
        /// `json_set`: create if missing, overwrite if present.
        case set
        /// `json_insert`: create only if missing (never overwrite an existing value).
        case insert
        /// `json_replace`: overwrite only if present (never create).
        case replace
    }

    /// SQLite-dialect set/insert/replace keyed by ``SQLiteJSONPath``. Non-throwing; an unresolvable or
    /// wrong-typed path is a no-op. Rules (matching `sqlite3`): a missing intermediate is created — an
    /// object for a following key, an array for a following index — but only if a value is actually
    /// placed beneath it; `[#]`, `[#-0]`, and an index equal to the array length append; an index past
    /// the length (or a `[#-N]` before the start) is a no-op; `.replace` never creates; `.insert` never
    /// overwrites; descending into an existing scalar, indexing an object, or keying an array is a
    /// no-op. An empty path (`$`) addresses the whole value (set/replace overwrite it; insert is a
    /// no-op since the root already exists).
    public func setting(_ path: SQLiteJSONPath, to value: JSONValue, mode: SQLiteSetMode) -> JSONValue {
        sqliteSet(path.segments[...], value, mode, 0)
    }

    /// SQLite-dialect removal keyed by ``SQLiteJSONPath`` (`json_remove`). Non-throwing; an
    /// unresolvable path is a no-op. Removing the whole value (an empty `$` path) returns `nil`.
    public func removing(_ path: SQLiteJSONPath) -> JSONValue? {
        path.segments.isEmpty ? nil : sqliteRemove(path.segments[...], 0)
    }

    // MARK: - Recursion

    private static func emptyContainer(for segment: SQLiteJSONPath.Segment) -> JSONValue {
        if case .key = segment { return .object([:]) }
        return .array([])  // .index / .fromEnd / .append
    }

    /// Where a segment lands in an array of `count` elements: an existing element, the append position
    /// (one past the end — from `[#]`, `[#-0]`, or an index equal to `count`), or out of range.
    private enum ArraySlot: Equatable { case existing(Int), append, outOfRange }

    private static func arraySlot(_ segment: SQLiteJSONPath.Segment, count: Int) -> ArraySlot {
        let index: Int
        switch segment {
        case .index(let i): index = i
        case .fromEnd(let n): index = count - n
        case .append: index = count
        case .key: return .outOfRange  // a key never resolves against an array
        }
        if index == count { return .append }
        if index >= 0 && index < count { return .existing(index) }
        return .outOfRange
    }

    private func sqliteSet(
        _ segments: ArraySlice<SQLiteJSONPath.Segment>, _ value: JSONValue, _ mode: SQLiteSetMode,
        _ depth: Int
    ) -> JSONValue {
        guard depth < Self.maxMutationDepth else { return self }  // fail closed: no-op
        guard let segment = segments.first else {
            return mode == .insert ? self : value  // `$`: insert is a no-op; set/replace overwrite
        }
        let rest = segments.dropFirst()
        switch segment {
        case .key(let key):
            guard case .object(var members) = self else { return self }  // wrong-type ⇒ no-op
            if rest.isEmpty {
                let exists = members[key] != nil
                switch mode {
                case .set: members[key] = value
                case .insert: if !exists { members[key] = value }
                case .replace: if exists { members[key] = value }
                }
            } else if let child = members[key] {
                members[key] = child.sqliteSet(rest, value, mode, depth + 1)
            } else if mode != .replace {
                let created = Self.emptyContainer(for: rest.first!)
                let result = created.sqliteSet(rest, value, mode, depth + 1)
                if result != created { members[key] = result }  // materialize only if a value was placed
            }
            return .object(members)

        case .index, .fromEnd, .append:
            guard case .array(var elements) = self else { return self }  // wrong-type ⇒ no-op
            let slot = Self.arraySlot(segment, count: elements.count)
            if rest.isEmpty {
                switch slot {
                case .existing(let i):
                    if mode != .insert { elements[i] = value }  // set/replace overwrite; insert no-ops
                case .append:
                    if mode != .replace { elements.append(value) }  // set/insert append; replace no-ops
                case .outOfRange:
                    break
                }
            } else {
                switch slot {
                case .existing(let i):
                    elements[i] = elements[i].sqliteSet(rest, value, mode, depth + 1)
                case .append:
                    if mode != .replace {
                        let created = Self.emptyContainer(for: rest.first!)
                        let result = created.sqliteSet(rest, value, mode, depth + 1)
                        if result != created { elements.append(result) }
                    }
                case .outOfRange:
                    break
                }
            }
            return .array(elements)
        }
    }

    private func sqliteRemove(_ segments: ArraySlice<SQLiteJSONPath.Segment>, _ depth: Int) -> JSONValue {
        guard depth < Self.maxMutationDepth else { return self }
        guard let segment = segments.first else { return self }
        let rest = segments.dropFirst()
        switch segment {
        case .key(let key):
            guard case .object(var members) = self else { return self }
            if rest.isEmpty {
                members[key] = nil  // remove if present, no-op if missing
            } else if let child = members[key] {
                members[key] = child.sqliteRemove(rest, depth + 1)
            }
            return .object(members)

        case .index, .fromEnd, .append:
            guard case .array(var elements) = self else { return self }
            guard case .existing(let i) = Self.arraySlot(segment, count: elements.count) else {
                return self  // append / out of range ⇒ nothing to remove
            }
            if rest.isEmpty {
                elements.remove(at: i)
            } else {
                elements[i] = elements[i].sqliteRemove(rest, depth + 1)
            }
            return .array(elements)
        }
    }
}
