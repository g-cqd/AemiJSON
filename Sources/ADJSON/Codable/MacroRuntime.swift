import Foundation

// ============================================================================
// MACRO RUNTIME — SPI (not API). The public-underscored symbols here
// (`_FastDecodeCursor`, `_JSONByteWriter`, `__adjsonDecode`, `__adjsonEncode`,
// `ADJSONFast*`) exist only for code emitted by the `@JSONCodable` macro and for
// hand-written fast conformances. They are intentionally underscored to signal
// "do not call directly": a macro cannot inject an `@_spi` import into the user's
// file, so public-underscored is the idiomatic way to expose a macro runtime.
// Treat as unstable; use `@JSONCodable` instead.
//
// The SPI is split across three files by concern:
//   • MacroRuntime.swift          — the protocols + the generic-dispatch entry (here).
//   • FastDecodeCursor.swift       — `_FastDecodeCursor`, the tape reader.
//   • FastBuiltinConformances.swift — built-in scalar/Array/Optional/Dictionary conformances.
// The encode-side value buffer lives in _JSONByteWriter.swift.
// ============================================================================

// Opt-in fast paths that bypass the Codable container protocols. The generic
// decoder/encoder dispatch to them when a value type opts in, so even `[User]` /
// nested types benefit.

public protocol ADJSONFastDecodable {
    static func __adjsonDecode(_ cursor: _FastDecodeCursor) throws -> Self
}

public protocol ADJSONFastEncodable {
    func __adjsonEncode(into writer: inout _JSONByteWriter) throws
}

struct StaticCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ s: StaticString) { stringValue = s.description }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension DecodeContext {
    /// Enter one native-recursion level of the (unavoidably recursive) Codable path, throwing a
    /// catchable `DecodingError` past `maxDecodeDepth` rather than overflowing the stack on deeply
    /// nested (or self-referential) input. The counter is self-balanced on the throwing path so a
    /// caller's `defer { popDepth() }` must NOT run when this throws — pair it as
    /// `try pushDepth(); defer { popDepth() }`. Both the generic dispatch (`decodeValue`) and the
    /// fast-container readers (`fastArray`/`fastDictionary`) flow through here, so every descent is
    /// counted (the fast path used to bypass the guard — see `FastDecodeCursor`).
    @inlinable func pushDepth() throws {
        decodeDepth += 1
        guard decodeDepth <= maxDecodeDepth else {
            decodeDepth -= 1  // balance the counter before throwing (no matching `popDepth` runs)
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: [],
                    debugDescription: "Decoding exceeded the maximum nesting depth (\(maxDecodeDepth))"))
        }
    }

    @inlinable func popDepth() { decodeDepth -= 1 }

    /// Decode any Decodable at a tape index — fast path if the type opts in, else
    /// the generic container path. The fast-path result is bound back to `T` with a
    /// conditional cast (the conformer is `T` by construction); if that ever failed
    /// we fall through to the generic decoder rather than trap.
    @inlinable func decodeValue<T: Decodable>(_ type: T.Type, at index: Int) throws -> T {
        try pushDepth()
        defer { popDepth() }
        if let fast = T.self as? any ADJSONFastDecodable.Type {
            if let value = try fast.__adjsonDecode(_FastDecodeCursor(ctx: self, index: index)) as? T {
                return value
            }
        }
        return try decodeGeneric(type, at: index)
    }

    /// Generic container fallback. Not `@inlinable` (it touches the internal
    /// `TapeDecoder`), but reachable from the inlinable `decodeValue`.
    @usableFromInline func decodeGeneric<T: Decodable>(_ type: T.Type, at index: Int) throws -> T {
        // `Date`/`Data` are intercepted here (this body is not serialized, so it can reference the
        // internal-imported Foundation types) and routed through their decoding strategy; neither is
        // a fast type, so a `Date`/`Data` always falls through `decodeValue` to here. The `as?` casts
        // always succeed (the metatype is checked first); the fall-through is unreachable.
        if T.self == Date.self, let date = try decodeDate(at: index) as? T { return date }
        if T.self == Data.self, let data = try decodeData(at: index) as? T { return data }
        return try T(from: TapeDecoder(ctx: self, index: index, codingPath: []))
    }
}
