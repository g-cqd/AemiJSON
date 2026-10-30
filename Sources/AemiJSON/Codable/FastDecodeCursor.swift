import AemiJSONCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

// The fast-path object reader handed to `@JSONCodable`-generated `__adjsonDecode`.
// Reads fields by statically-known key directly off the tape — no `KeyedDecodingContainer`,
// no per-field `String` key allocation. Part of the macro runtime SPI (see MacroRuntime.swift).

extension DecodeContext {
    /// Value-slot index for a statically-known key, matched on raw bytes (no String
    /// alloc). Returns the LAST match (duplicate keys resolve last-value-wins).
    ///
    /// Throws `typeMismatch` when the node at `obj` is not an object. Only an object slot carries a
    /// member count: a string's slot holds `(length << 2) | flags` in the same field, so walking it as
    /// members would read past the end of the tape.
    @inlinable func memberValueIndex(of obj: Int, keyBytes lit: StaticString) throws -> Int? {
        let s = slot(obj)
        guard Slot.tag(s) == JSONKind.object.rawValue else { throw objectExpected(codingPath: []) }
        let c = Slot.count(s)
        var i = obj + 1
        var found: Int? = nil
        for _ in 0 ..< c {
            let ks = uncheckedSlot(i)
            let valIdx = i + 1
            let koff = Slot.low(ks)
            let klen = Slot.length(ks)
            assertBytes(koff, klen)
            #if DEBUG
                keyComparisons?.count += 1
            #endif
            if JSONKey.matches(bytes, koff, klen, escaped: Slot.flags(ks) & 1 == 1, json5: doc.isJSON5, lit) {
                found = valIdx
                if keysAreUnique { break }  // unique keys → first match is the only match
            }
            i = uncheckedNextIndex(after: valIdx)
        }
        return found
    }
}

/// Reads fields of one JSON object by statically-known key. Handed to generated
/// `__adjsonDecode`. Construction is internal; only its read methods are public.
public struct _FastDecodeCursor {
    @usableFromInline let ctx: DecodeContext
    @usableFromInline let index: Int

    @usableFromInline init(ctx: DecodeContext, index: Int) {
        self.ctx = ctx
        self.index = index
    }

    /// The value of `key` read by `read`; `keyNotFound` when the key is absent or `read` gives nil (roadmap 0009 is
    /// to tell a wrong type from an absent key).
    @inlinable func required<T>(_ key: StaticString, _ read: (Int) -> T?) throws -> T {
        guard let vi = try ctx.memberValueIndex(of: index, keyBytes: key), let value = read(vi) else {
            throw missing(key)
        }
        return value
    }

    /// The value of `key` read by `read`; nil when the key is absent or null.
    @inlinable func optional<T>(_ key: StaticString, _ read: (Int) -> T?) throws -> T? {
        guard let vi = try ctx.memberValueIndex(of: index, keyBytes: key), !ctx.isNull(vi) else { return nil }
        return read(vi)
    }

    @inlinable public func string(_ key: StaticString) throws -> String { try required(key) { ctx.string($0) } }

    @inlinable public func stringIfPresent(_ key: StaticString) throws -> String? {
        try optional(key) { ctx.string($0) }
    }

    @inlinable public func bool(_ key: StaticString) throws -> Bool { try required(key) { ctx.bool($0) } }

    @inlinable public func boolIfPresent(_ key: StaticString) throws -> Bool? { try optional(key) { ctx.bool($0) } }

    @inlinable public func double(_ key: StaticString) throws -> Double { try required(key) { ctx.double($0) } }

    @inlinable public func doubleIfPresent(_ key: StaticString) throws -> Double? {
        try optional(key) { ctx.double($0) }
    }

    @inlinable public func integer<T: FixedWidthInteger>(_ key: StaticString, _ type: T.Type) throws -> T {
        try required(key) { ctx.integer($0, type) }
    }

    @inlinable public func integerIfPresent<T: FixedWidthInteger>(_ key: StaticString, _ type: T.Type) throws -> T? {
        try optional(key) { ctx.integer($0, type) }
    }

    @inlinable public func decode<T: Decodable>(_ type: T.Type, _ key: StaticString) throws -> T {
        guard let vi = try ctx.memberValueIndex(of: index, keyBytes: key) else { throw missing(key) }
        return try field(type, vi, key)
    }

    @inlinable public func decodeIfPresent<T: Decodable>(_ type: T.Type, _ key: StaticString) throws -> T? {
        guard let vi = try ctx.memberValueIndex(of: index, keyBytes: key), !ctx.isNull(vi) else { return nil }
        return try field(type, vi, key)
    }

    /// The field `key` at value index `vi`, an error in it reported under the field.
    @inlinable func field<T: Decodable>(_ type: T.Type, _ vi: Int, _ key: StaticString) throws -> T {
        do {
            return try ctx.decodeValue(type, at: vi)
        } catch let error as DecodingError {
            throw error.prefixed(field: key)
        }
    }

    @usableFromInline func missing(_ key: StaticString) -> DecodingError {
        .keyNotFound(StaticCodingKey(key), .init(codingPath: [], debugDescription: "No value for key \(key)"))
    }
}

extension _FastDecodeCursor {
    /// Decode an array whose elements opt into the fast path, with no generic
    /// unkeyed container / existential boxing per element.
    @inlinable public func fastArray<U: AemiJSONFastDecodable>(_ type: U.Type) throws -> [U] {
        guard ctx.tag(index) == JSONKind.array.rawValue else {
            throw DecodingError.typeMismatch([U].self, .init(codingPath: [], debugDescription: "Expected array"))
        }
        let count = ctx.count(index)
        var out: [U] = []
        out.reserveCapacity(count)
        var i = index + 1
        // Count this container against the decode-depth budget: elements are decoded by calling
        // `__adjsonDecode` directly (not via `ctx.decodeValue`), so without this a nest of fast
        // containers (`[[[Int]]]`, recursive `@JSONCodable` types) would recurse unguarded.
        try ctx.pushDepth()
        defer { ctx.popDepth() }
        for position in 0 ..< count {
            do {
                out.append(try U.__adjsonDecode(_FastDecodeCursor(ctx: ctx, index: i)))
            } catch let error as DecodingError {
                throw error.prefixed(index: position)
            }
            i = ctx.uncheckedNextIndex(after: i)
        }
        return out
    }

    @inlinable public func currentString() throws -> String {
        guard let s = ctx.string(index) else { throw mismatch(String.self) }
        return s
    }
    @inlinable public func currentBool() throws -> Bool {
        guard let b = ctx.bool(index) else { throw mismatch(Bool.self) }
        return b
    }
    @inlinable public func currentDouble() throws -> Double {
        guard let d = ctx.double(index) else { throw mismatch(Double.self) }
        return d
    }
    /// Parse the current number node straight to `Float` (single rounding via ``DecodeContext/float``),
    /// not `Float(currentDouble())` — narrowing a `Double` rounds twice and can land on a different
    /// `Float` bit pattern than rounding the source decimal directly.
    @inlinable public func currentFloat() throws -> Float {
        guard let f = ctx.float(index) else { throw mismatch(Float.self) }
        return f
    }
    @inlinable public func currentInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard let n = ctx.integer(index, type) else { throw mismatch(T.self) }
        return n
    }
    @inlinable public var currentIsNull: Bool { ctx.isNull(index) }

    /// Decode an object whose values opt into the fast path into `[String: V]`.
    @inlinable public func fastDictionary<V: AemiJSONFastDecodable>(_ type: V.Type) throws -> [String: V] {
        guard ctx.tag(index) == JSONKind.object.rawValue else {
            throw DecodingError.typeMismatch(
                [String: V].self, .init(codingPath: [], debugDescription: "Expected object"))
        }
        let count = ctx.count(index)
        var out = [String: V](minimumCapacity: count)
        var i = index + 1
        // See `fastArray`: values are decoded via `__adjsonDecode` directly, so this container must
        // be counted against the decode-depth budget to bound a nest of fast containers.
        try ctx.pushDepth()
        defer { ctx.popDepth() }
        for _ in 0 ..< count {
            let key = ctx.decodeString(ctx.uncheckedSlot(i))
            do {
                out[key] = try V.__adjsonDecode(_FastDecodeCursor(ctx: ctx, index: i + 1))
            } catch let error as DecodingError {
                throw error.prefixed(member: key)
            }
            i = ctx.uncheckedNextIndex(after: i + 1)
        }
        return out
    }

    @usableFromInline func mismatch(_ type: Any.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: [], debugDescription: "Expected \(type)"))
    }
}

// MARK: - Single-pass decoding

// `@JSONCodable` resolves every field's value index in ONE walk of the object via `forEachMember`,
// then decodes each field from its index — O(K) instead of O(fields × K) repeated key scans. The
// `*At` readers mirror the by-key readers above but take a pre-resolved value index (`vi < 0` means
// the key was absent).
extension _FastDecodeCursor {
    /// A member key matched against a statically-known literal on raw bytes — no String allocation
    /// for the common (unescaped) case.
    public struct _FastKey {
        @usableFromInline let ctx: DecodeContext
        @usableFromInline let off: Int
        @usableFromInline let len: Int
        @usableFromInline let escaped: Bool
        @inlinable init(ctx: DecodeContext, off: Int, len: Int, escaped: Bool) {
            self.ctx = ctx
            self.off = off
            self.len = len
            self.escaped = escaped
        }
        @inlinable public func matches(_ s: StaticString) -> Bool {
            ctx.checkLive()  // reads the bytes without a slot read, so it checks for itself
            return JSONKey.matches(ctx.bytes, off, len, escaped: escaped, json5: ctx.doc.isJSON5, s)
        }
    }

    /// Throws `typeMismatch` unless the node at the cursor is an object: the error synthesized
    /// `Codable` raises for a non-object, which ``forEachMember(_:)`` alone never reports. Generated
    /// `__adjsonDecode` bodies call it first.
    @inlinable public func requireObject() throws {
        guard ctx.tag(index) == JSONKind.object.rawValue else { throw ctx.objectExpected(codingPath: []) }
    }

    /// Walk the object's members once, in document order, handing each `(key, value-index)` to
    /// `body`. A later duplicate key overwrites an earlier match, so callers preserve last-value-wins.
    /// Visits nothing when the node is not an object; see ``requireObject()``.
    @inlinable public func forEachMember(_ body: (_FastKey, Int) -> Void) {
        guard ctx.tag(index) == JSONKind.object.rawValue else { return }
        let c = ctx.count(index)
        var i = index + 1
        for _ in 0 ..< c {
            let ks = ctx.uncheckedSlot(i)
            let key = _FastKey(
                ctx: ctx, off: Slot.low(ks), len: Slot.length(ks), escaped: Slot.flags(ks) & 1 == 1)
            body(key, i + 1)
            i = ctx.uncheckedNextIndex(after: i + 1)
        }
    }

    @inlinable public func stringAt(_ vi: Int, _ key: StaticString) throws -> String {
        guard vi >= 0, let s = ctx.string(vi) else { throw missing(key) }
        return s
    }
    @inlinable public func stringIfPresentAt(_ vi: Int) -> String? {
        guard vi >= 0, !ctx.isNull(vi) else { return nil }
        return ctx.string(vi)
    }
    @inlinable public func boolAt(_ vi: Int, _ key: StaticString) throws -> Bool {
        guard vi >= 0, let b = ctx.bool(vi) else { throw missing(key) }
        return b
    }
    @inlinable public func boolIfPresentAt(_ vi: Int) -> Bool? {
        guard vi >= 0, !ctx.isNull(vi) else { return nil }
        return ctx.bool(vi)
    }
    @inlinable public func doubleAt(_ vi: Int, _ key: StaticString) throws -> Double {
        guard vi >= 0, let d = ctx.double(vi) else { throw missing(key) }
        return d
    }
    @inlinable public func doubleIfPresentAt(_ vi: Int) -> Double? {
        guard vi >= 0, !ctx.isNull(vi) else { return nil }
        return ctx.double(vi)
    }
    @inlinable public func integerAt<T: FixedWidthInteger>(
        _ vi: Int, _ key: StaticString, _ type: T.Type
    )
        throws -> T
    {
        guard vi >= 0, let n = ctx.integer(vi, type) else { throw missing(key) }
        return n
    }
    @inlinable public func integerIfPresentAt<T: FixedWidthInteger>(_ vi: Int, _ type: T.Type) -> T? {
        guard vi >= 0, !ctx.isNull(vi) else { return nil }
        return ctx.integer(vi, type)
    }
    @inlinable public func decodeAt<T: Decodable>(_ type: T.Type, _ vi: Int, _ key: StaticString) throws -> T {
        guard vi >= 0 else { throw missing(key) }
        return try field(type, vi, key)
    }
    @inlinable public func decodeIfPresentAt<T: Decodable>(_ type: T.Type, _ vi: Int) throws -> T? {
        guard vi >= 0, !ctx.isNull(vi) else { return nil }
        return try ctx.decodeValue(type, at: vi)
    }
}
