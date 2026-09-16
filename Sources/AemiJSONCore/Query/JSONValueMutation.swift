import OrderedCollections

// RFC 6901 JSON Pointer access and the tree-mutation primitives behind JSON Patch
// (RFC 6902). These live in the Query layer — not in `Value` — so the value model stays
// pure data + (de)serialization and the addressing/patch error domain is owned here.
//
// `adding`/`removing`/`replacing` walk the pointer path with an explicit `descend` frame stack and
// rebuild the spine bottom-up — no native recursion, so a pathologically deep (often attacker-built)
// pointer cannot overflow the stack; depth is bounded only by the `maxMutationDepth` frame-array cap,
// which throws `JSONPatchError.depthExceeded`. Only the containers ON the path are rebuilt; every
// untouched subtree stays shared. (`value(at:)` is likewise iterative.)

extension JSONValue {
    /// Upper bound on pointer-path depth for the mutation primitives. The walk is iterative, so this
    /// is a memory cap on the `descend` frame array (not a stack-overflow guard) — sized well above
    /// any real pointer depth; a deeper (usually attacker-built) path throws `depthExceeded`.
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

    /// One descended container on the path from the root to the mutation point:
    /// the container value and the token taken from it to reach the next level.
    private typealias Frame = (container: JSONValue, token: String)

    /// Walks `tokens` to the container that holds the FINAL token, recording each
    /// ancestor container and the token taken from it. Returns nil for an empty
    /// path (the caller decides what that means per operation). Fully iterative —
    /// a pathologically deep pointer can't overflow the stack; depth is bounded by
    /// the `maxMutationDepth` frame-array cap. Every intermediate child is required
    /// to exist (a missing one is `pathNotFound`).
    private func descend(
        _ tokens: ArraySlice<String>
    ) throws(JSONPatchError) -> (frames: [Frame], leaf: JSONValue, last: String)? {
        guard tokens.count <= Self.maxMutationDepth else { throw JSONPatchError.depthExceeded }
        guard let last = tokens.last else { return nil }
        var frames: [Frame] = []
        frames.reserveCapacity(tokens.count - 1)
        var node = self
        var index = tokens.startIndex
        let stop = tokens.index(before: tokens.endIndex)
        while index < stop {
            let token = tokens[index]
            switch node {
                case .object(let members):
                    guard let child = members[token] else { throw JSONPatchError.pathNotFound }
                    frames.append((node, token))
                    node = child
                case .array(let elements):
                    guard let i = JSONPointer.arrayIndex(token), i < elements.count else {
                        throw JSONPatchError.pathNotFound
                    }
                    frames.append((node, token))
                    node = elements[i]
                default:
                    throw JSONPatchError.pathNotFound
            }
            index = tokens.index(after: index)
        }
        return (frames, node, last)
    }

    /// Folds a rewritten leaf back up the spine: only the containers on the path
    /// are rebuilt (each frame's child slot was proven to exist in `descend`, so
    /// this can't fail), leaving every untouched subtree shared.
    private static func rebuild(_ frames: [Frame], _ child: JSONValue) -> JSONValue {
        var result = child
        for frame in frames.reversed() {
            switch frame.container {
                case .object(var members):
                    members[frame.token] = result
                    result = .object(members)
                case .array(var elements):
                    if let i = JSONPointer.arrayIndex(frame.token), i < elements.count {
                        elements[i] = result
                    }
                    result = .array(elements)
                default:
                    break  // unreachable: `descend` only frames object/array containers
            }
        }
        return result
    }

    func adding(_ tokens: ArraySlice<String>, _ value: JSONValue) throws(JSONPatchError) -> JSONValue {
        guard let (frames, leaf, last) = try descend(tokens) else { return value }  // empty path replaces the root
        let newLeaf: JSONValue
        switch leaf {
            case .object(var members):
                members[last] = value
                newLeaf = .object(members)
            case .array(var elements):
                if last == "-" {
                    elements.append(value)
                } else {
                    guard let i = JSONPointer.arrayIndex(last), i <= elements.count else {
                        throw JSONPatchError.pathNotFound
                    }
                    elements.insert(value, at: i)
                }
                newLeaf = .array(elements)
            default:
                throw JSONPatchError.pathNotFound
        }
        return Self.rebuild(frames, newLeaf)
    }

    func removing(_ tokens: ArraySlice<String>) throws(JSONPatchError) -> JSONValue {
        guard let (frames, leaf, last) = try descend(tokens) else { throw JSONPatchError.pathNotFound }
        let newLeaf: JSONValue
        switch leaf {
            case .object(var members):
                guard members[last] != nil else { throw JSONPatchError.pathNotFound }
                members[last] = nil
                newLeaf = .object(members)
            case .array(var elements):
                guard let i = JSONPointer.arrayIndex(last), i < elements.count else {
                    throw JSONPatchError.pathNotFound
                }
                elements.remove(at: i)
                newLeaf = .array(elements)
            default:
                throw JSONPatchError.pathNotFound
        }
        return Self.rebuild(frames, newLeaf)
    }

    func replacing(_ tokens: ArraySlice<String>, _ value: JSONValue) throws(JSONPatchError) -> JSONValue {
        guard let (frames, leaf, last) = try descend(tokens) else { return value }
        let newLeaf: JSONValue
        switch leaf {
            case .object(var members):
                guard members[last] != nil else { throw JSONPatchError.pathNotFound }
                members[last] = value
                newLeaf = .object(members)
            case .array(var elements):
                guard let i = JSONPointer.arrayIndex(last), i < elements.count else {
                    throw JSONPatchError.pathNotFound
                }
                elements[i] = value
                newLeaf = .array(elements)
            default:
                throw JSONPatchError.pathNotFound
        }
        return Self.rebuild(frames, newLeaf)
    }
}

public enum JSONPatchError: Error, Sendable, Equatable {
    case pathNotFound
    case testFailed
    case invalidOperation
    /// A pointer path nested past the mutation depth cap — rejected to bound native
    /// recursion (a pathologically deep, usually attacker-supplied, path).
    case depthExceeded
}
