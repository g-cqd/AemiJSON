#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

// Coding paths cost nothing on success (roadmap 0005). A decoder or encoder made for a value knows only the path below that value: its
// containers carry the keys and positions they add (`nestedContainer`, `superDecoder`), and the errors they throw carry that relative path.
// Each place that hands a value to a fresh decoder or encoder (a keyed, unkeyed or single-value `decode`/`encode` of a generic value, and the
// fast path's arrays, dictionaries and fields) catches the error on its way out and puts its own path in front. By the time the error
// leaves the top-level call its path runs from the root, as Foundation's does.

extension DecodingError {
    /// This error with `prefix` before its coding path.
    @usableFromInline func prefixed(_ prefix: [any CodingKey]) -> DecodingError {
        guard !prefix.isEmpty else { return self }
        switch self {
            case .typeMismatch(let type, let context): return .typeMismatch(type, context.prefixed(prefix))
            case .valueNotFound(let type, let context): return .valueNotFound(type, context.prefixed(prefix))
            case .keyNotFound(let key, let context): return .keyNotFound(key, context.prefixed(prefix))
            case .dataCorrupted(let context): return .dataCorrupted(context.prefixed(prefix))
            @unknown default: return self
        }
    }

    /// This error under the array position `index`.
    @usableFromInline func prefixed(index: Int) -> DecodingError { prefixed([IndexKey(index)]) }

    /// This error under the object member `key`, as the document spells it.
    @usableFromInline func prefixed(member key: String) -> DecodingError { prefixed([MemberKey(key)]) }

    /// This error under a `@JSONCodable` field.
    @usableFromInline func prefixed(field key: StaticString) -> DecodingError { prefixed([StaticCodingKey(key)]) }
}

extension DecodingError.Context {
    fileprivate func prefixed(_ prefix: [any CodingKey]) -> Self {
        .init(codingPath: prefix + codingPath, debugDescription: debugDescription, underlyingError: underlyingError)
    }
}

extension EncodingError {
    /// This error with `prefix` before its coding path.
    func prefixed(_ prefix: [any CodingKey]) -> EncodingError {
        guard !prefix.isEmpty, case .invalidValue(let value, let context) = self else { return self }
        return .invalidValue(
            value,
            .init(
                codingPath: prefix + context.codingPath, debugDescription: context.debugDescription,
                underlyingError: context.underlyingError))
    }
}

/// A member key of a decoded dictionary, for a coding path.
struct MemberKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ key: String) { stringValue = key }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
