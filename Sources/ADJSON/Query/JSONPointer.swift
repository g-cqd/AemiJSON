import Foundation

/// RFC 6901 JSON Pointer. `""` is the whole document; otherwise a sequence of
/// `/`-separated reference tokens with `~1`→`/` and `~0`→`~` unescaping.
public struct JSONPointer: Sendable, Equatable {
    public let tokens: [String]

    public init(tokens: [String]) { self.tokens = tokens }

    public init(_ string: String) throws {
        if string.isEmpty {
            tokens = []
            return
        }
        guard string.hasPrefix("/") else {
            throw JSONError.unexpectedCharacter(string.utf8.first ?? 0, at: 0)
        }
        tokens = string.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(Self.unescape)
    }

    static func unescape(_ s: Substring) -> String {
        s.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
}

extension JSON {
    /// Resolve an RFC 6901 pointer. Returns a missing value if any token doesn't resolve.
    public subscript(pointer pointer: JSONPointer) -> JSON {
        var current = self
        for token in pointer.tokens {
            if current.isObject {
                current = current[token]
            } else if current.isArray, let i = Int(token) {
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
