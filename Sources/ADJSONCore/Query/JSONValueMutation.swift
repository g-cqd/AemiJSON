import OrderedCollections

// RFC 6901 JSON Pointer access and the tree-mutation primitives behind JSON Patch
// (RFC 6902). These live in the Query layer — not in `Value` — so the value model stays
// pure data + (de)serialization and the addressing/patch error domain is owned here.
// Recursion depth is bounded by the structure's own depth, which for parsed input is
// capped by the parser's `maxDepth` (512); see `JSONParseOptions`.

extension JSONValue {
    /// The value at an RFC 6901 pointer, or nil if it doesn't resolve.
    public func value(at pointer: JSONPointer) -> JSONValue? {
        var current = self
        for token in pointer.tokens {
            switch current {
            case .object(let members):
                guard let next = members[token] else { return nil }
                current = next
            case .array(let elements):
                guard let i = JSONPointer.arrayIndex(token), i < elements.count else { return nil }
                current = elements[i]
            default:
                return nil
            }
        }
        return current
    }

    func adding(_ tokens: ArraySlice<String>, _ value: JSONValue) throws(JSONPatchError) -> JSONValue {
        guard let first = tokens.first else { return value }  // empty path replaces the root
        let rest = tokens.dropFirst()
        switch self {
        case .object(var members):
            if rest.isEmpty {
                members[first] = value
            } else {
                guard let child = members[first] else { throw JSONPatchError.pathNotFound }
                members[first] = try child.adding(rest, value)
            }
            return .object(members)
        case .array(var elements):
            if rest.isEmpty {
                if first == "-" {
                    elements.append(value)
                } else {
                    guard let i = JSONPointer.arrayIndex(first), i <= elements.count else {
                        throw JSONPatchError.pathNotFound
                    }
                    elements.insert(value, at: i)
                }
            } else {
                guard let i = JSONPointer.arrayIndex(first), i < elements.count else {
                    throw JSONPatchError.pathNotFound
                }
                elements[i] = try elements[i].adding(rest, value)
            }
            return .array(elements)
        default:
            throw JSONPatchError.pathNotFound
        }
    }

    func removing(_ tokens: ArraySlice<String>) throws(JSONPatchError) -> JSONValue {
        guard let first = tokens.first else { throw JSONPatchError.pathNotFound }
        let rest = tokens.dropFirst()
        switch self {
        case .object(var members):
            guard let existing = members[first] else { throw JSONPatchError.pathNotFound }
            if rest.isEmpty {
                members[first] = nil
            } else {
                members[first] = try existing.removing(rest)
            }
            return .object(members)
        case .array(var elements):
            guard let i = JSONPointer.arrayIndex(first), i < elements.count else { throw JSONPatchError.pathNotFound }
            if rest.isEmpty {
                elements.remove(at: i)
            } else {
                elements[i] = try elements[i].removing(rest)
            }
            return .array(elements)
        default:
            throw JSONPatchError.pathNotFound
        }
    }

    func replacing(_ tokens: ArraySlice<String>, _ value: JSONValue) throws(JSONPatchError) -> JSONValue {
        guard let first = tokens.first else { return value }
        let rest = tokens.dropFirst()
        switch self {
        case .object(var members):
            guard let existing = members[first] else { throw JSONPatchError.pathNotFound }
            members[first] = rest.isEmpty ? value : try existing.replacing(rest, value)
            return .object(members)
        case .array(var elements):
            guard let i = JSONPointer.arrayIndex(first), i < elements.count else { throw JSONPatchError.pathNotFound }
            elements[i] = rest.isEmpty ? value : try elements[i].replacing(rest, value)
            return .array(elements)
        default:
            throw JSONPatchError.pathNotFound
        }
    }
}

public enum JSONPatchError: Error, Sendable, Equatable {
    case pathNotFound
    case testFailed
    case invalidOperation
}
