/// Errors from parsing or resolving a JSON Pointer (RFC 6901) or Relative JSON Pointer.
/// Distinct from `JSONPatchError` so the addressing layer doesn't depend on the patch layer.
public enum JSONPointerError: Error, Sendable, Equatable {
    case invalidSyntax
    case notFound
}

/// RFC 6901 JSON Pointer. `""` is the whole document; otherwise a sequence of
/// `/`-separated reference tokens with `~1`→`/` and `~0`→`~` unescaping.
public struct JSONPointer: Sendable, Equatable {
    public let tokens: [String]

    public init(tokens: [String]) { self.tokens = tokens }

    public init(_ string: String) throws(JSONPointerError) {
        if string.isEmpty {
            tokens = []
            return
        }
        guard string.hasPrefix("/") else { throw JSONPointerError.invalidSyntax }
        tokens = string.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(Self.unescape)
    }

    static func unescape(_ s: Substring) -> String {
        // RFC 6901 §4: `~1` → `/`, `~0` → `~`. A single left-to-right pass (escape last)
        // avoids Foundation's `replacingOccurrences` so this stays dependency-free.
        guard s.contains("~") else { return String(s) }
        var out = String()
        out.reserveCapacity(s.count)
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "~" else {
                out.append(c)
                continue
            }
            switch it.next() {
            case "1": out.append("/")
            case "0": out.append("~")
            case let other?:
                out.append("~")
                out.append(other)
            case nil: out.append("~")
            }
        }
        return out
    }

    /// Parse an RFC 6901 §4 array-index token: exactly `0` or `[1-9][0-9]*`. Rejects a
    /// leading `+`, sign, leading zero, or surrounding whitespace that `Int(_:)` would
    /// otherwise accept. Returns nil for `-` (the RFC 6902 "end of array" token) and any
    /// non-conforming token.
    static func arrayIndex(_ token: String) -> Int? {
        let u = token.utf8
        guard let first = u.first else { return nil }
        if first == 0x30 { return u.count == 1 ? 0 : nil }  // "0", never "01"
        guard first >= 0x31, first <= 0x39 else { return nil }
        for b in u where b < 0x30 || b > 0x39 { return nil }
        return Int(token)
    }

    /// True if `self` addresses a strict ancestor of `other`. RFC 6902 §4.4 forbids a
    /// `move` whose `from` is a proper prefix of `path` (moving a value into its own child).
    func isProperPrefix(of other: JSONPointer) -> Bool {
        tokens.count < other.tokens.count && other.tokens.starts(with: tokens)
    }
}

extension JSON {
    /// Resolve an RFC 6901 pointer. Returns a missing value if any token doesn't resolve.
    public subscript(pointer pointer: JSONPointer) -> JSON {
        var current = self
        for token in pointer.tokens {
            if current.isObject {
                current = current[token]
            } else if current.isArray, let i = JSONPointer.arrayIndex(token) {
                current = current[index: i]
            } else {
                return JSON.missing(doc)
            }
            if !current.exists { return current }
        }
        return current
    }

    public subscript(pointer string: String) -> JSON {
        guard let pointer = try? JSONPointer(string) else { return JSON.missing(doc) }
        return self[pointer: pointer]
    }
}
