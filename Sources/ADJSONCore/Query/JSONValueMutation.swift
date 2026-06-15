import OrderedCollections

// RFC 6901 JSON Pointer access and the tree-mutation primitives behind JSON Patch
// (RFC 6902). These live in the Query layer — not in `Value` — so the value model stays
// pure data + (de)serialization and the addressing/patch error domain is owned here.
//
// `adding`/`removing`/`replacing` recurse once per consumed pointer token (the path depth, which
// the patch document controls). For a parsed patch that is bounded by the parser's `maxDepth`, but
// a programmatically-built `JSONPointer` (or a multi-megabyte path string) is not — so each guards
// against `maxMutationDepth` and throws `JSONPatchError.depthExceeded` rather than overflowing the
// stack. (`value(at:)` is already iterative.) Converting these to an explicit stack is a follow-up.

extension JSONValue {
    /// Native-recursion cap for the pointer-mutation primitives. Sized well above any real pointer
    /// depth yet far below the stack-overflow point on a small worker thread; frames here are light
    /// (a switch + a copy-on-write container reference), so this is independent of the heavier
    /// decode/encode caps and the parser's `maxDepth`.
    static let maxMutationDepth = 256

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

    func adding(_ tokens: ArraySlice<String>, _ value: JSONValue, _ depth: Int = 0) throws(JSONPatchError) -> JSONValue
    {
        guard depth < Self.maxMutationDepth else { throw JSONPatchError.depthExceeded }
        guard let first = tokens.first else { return value }  // empty path replaces the root
        let rest = tokens.dropFirst()
        switch self {
        case .object(var members):
            if rest.isEmpty {
                members[first] = value
            } else {
                guard let child = members[first] else { throw JSONPatchError.pathNotFound }
                members[first] = try child.adding(rest, value, depth + 1)
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
                elements[i] = try elements[i].adding(rest, value, depth + 1)
            }
            return .array(elements)
        default:
            throw JSONPatchError.pathNotFound
        }
    }

    func removing(_ tokens: ArraySlice<String>, _ depth: Int = 0) throws(JSONPatchError) -> JSONValue {
        guard depth < Self.maxMutationDepth else { throw JSONPatchError.depthExceeded }
        guard let first = tokens.first else { throw JSONPatchError.pathNotFound }
        let rest = tokens.dropFirst()
        switch self {
        case .object(var members):
            guard let existing = members[first] else { throw JSONPatchError.pathNotFound }
            if rest.isEmpty {
                members[first] = nil
            } else {
                members[first] = try existing.removing(rest, depth + 1)
            }
            return .object(members)
        case .array(var elements):
            guard let i = JSONPointer.arrayIndex(first), i < elements.count else { throw JSONPatchError.pathNotFound }
            if rest.isEmpty {
                elements.remove(at: i)
            } else {
                elements[i] = try elements[i].removing(rest, depth + 1)
            }
            return .array(elements)
        default:
            throw JSONPatchError.pathNotFound
        }
    }

    func replacing(
        _ tokens: ArraySlice<String>, _ value: JSONValue, _ depth: Int = 0
    ) throws(JSONPatchError)
        -> JSONValue
    {
        guard depth < Self.maxMutationDepth else { throw JSONPatchError.depthExceeded }
        guard let first = tokens.first else { return value }
        let rest = tokens.dropFirst()
        switch self {
        case .object(var members):
            guard let existing = members[first] else { throw JSONPatchError.pathNotFound }
            members[first] = rest.isEmpty ? value : try existing.replacing(rest, value, depth + 1)
            return .object(members)
        case .array(var elements):
            guard let i = JSONPointer.arrayIndex(first), i < elements.count else { throw JSONPatchError.pathNotFound }
            elements[i] = rest.isEmpty ? value : try elements[i].replacing(rest, value, depth + 1)
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
    /// A pointer path nested past ``JSONValue/maxMutationDepth`` — rejected to bound native
    /// recursion (a pathologically deep, usually attacker-supplied, path).
    case depthExceeded
}
