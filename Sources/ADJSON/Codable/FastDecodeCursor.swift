import Foundation

// The fast-path object reader handed to `@JSONCodable`-generated `__adjsonDecode`.
// Reads fields by statically-known key directly off the tape — no `KeyedDecodingContainer`,
// no per-field `String` key allocation. Part of the macro runtime SPI (see MacroRuntime.swift).

extension DecodeContext {
    /// Value-slot index for a statically-known key, matched on raw bytes (no String
    /// alloc). Returns the LAST match (duplicate keys resolve last-value-wins).
    @inlinable func memberValueIndex(of obj: Int, keyBytes lit: StaticString) -> Int? {
        let c = Slot.count(slot(obj))
        var i = obj + 1
        let target = lit.utf8Start
        let tlen = lit.utf8CodeUnitCount
        var found: Int? = nil
        for _ in 0..<c {
            let ks = slot(i)
            let valIdx = i + 1
            let koff = Slot.low(ks), klen = Slot.length(ks)
            assertBytes(koff, klen)
            if Slot.flags(ks) & 1 == 0 {
                if klen == tlen, JSONKey.bytesEqual(bytes + koff, target, tlen) { found = valIdx }
            } else if JSONString.unescape(bytes, koff, klen) == lit.description {
                found = valIdx
            }
            i = nextIndex(after: valIdx)
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

    @inlinable public func string(_ key: StaticString) throws -> String {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), let s = ctx.string(vi) else {
            throw missing(key)
        }
        return s
    }

    @inlinable public func stringIfPresent(_ key: StaticString) -> String? {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), !ctx.isNull(vi) else { return nil }
        return ctx.string(vi)
    }

    @inlinable public func bool(_ key: StaticString) throws -> Bool {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), let b = ctx.bool(vi) else { throw missing(key) }
        return b
    }

    @inlinable public func boolIfPresent(_ key: StaticString) -> Bool? {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), !ctx.isNull(vi) else { return nil }
        return ctx.bool(vi)
    }

    @inlinable public func double(_ key: StaticString) throws -> Double {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), let d = ctx.double(vi) else {
            throw missing(key)
        }
        return d
    }

    @inlinable public func doubleIfPresent(_ key: StaticString) -> Double? {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), !ctx.isNull(vi) else { return nil }
        return ctx.double(vi)
    }

    @inlinable public func integer<T: FixedWidthInteger>(_ key: StaticString, _ type: T.Type) throws -> T {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), let n = ctx.integer(vi, type) else {
            throw missing(key)
        }
        return n
    }

    @inlinable public func integerIfPresent<T: FixedWidthInteger>(_ key: StaticString, _ type: T.Type) -> T? {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), !ctx.isNull(vi) else { return nil }
        return ctx.integer(vi, type)
    }

    @inlinable public func decode<T: Decodable>(_ type: T.Type, _ key: StaticString) throws -> T {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key) else { throw missing(key) }
        return try ctx.decodeValue(type, at: vi)
    }

    @inlinable public func decodeIfPresent<T: Decodable>(_ type: T.Type, _ key: StaticString) throws -> T? {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), !ctx.isNull(vi) else { return nil }
        return try ctx.decodeValue(type, at: vi)
    }

    @usableFromInline func missing(_ key: StaticString) -> DecodingError {
        .keyNotFound(StaticCodingKey(key), .init(codingPath: [], debugDescription: "No value for key \(key)"))
    }
}

extension _FastDecodeCursor {
    /// Decode an array whose elements opt into the fast path, with no generic
    /// unkeyed container / existential boxing per element.
    @inlinable public func fastArray<U: ADJSONFastDecodable>(_ type: U.Type) throws -> [U] {
        guard ctx.tag(index) == JSONKind.array.rawValue else {
            throw DecodingError.typeMismatch([U].self, .init(codingPath: [], debugDescription: "Expected array"))
        }
        let count = ctx.count(index)
        var out = [U]()
        out.reserveCapacity(count)
        var i = index + 1
        for _ in 0..<count {
            out.append(try U.__adjsonDecode(_FastDecodeCursor(ctx: ctx, index: i)))
            i = ctx.nextIndex(after: i)
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
    @inlinable public func currentInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard let n = ctx.integer(index, type) else { throw mismatch(T.self) }
        return n
    }
    @inlinable public var currentIsNull: Bool { ctx.isNull(index) }

    /// Decode an object whose values opt into the fast path into `[String: V]`.
    @inlinable public func fastDictionary<V: ADJSONFastDecodable>(_ type: V.Type) throws -> [String: V] {
        guard ctx.tag(index) == JSONKind.object.rawValue else {
            throw DecodingError.typeMismatch(
                [String: V].self, .init(codingPath: [], debugDescription: "Expected object"))
        }
        let count = ctx.count(index)
        var out = [String: V](minimumCapacity: count)
        var i = index + 1
        for _ in 0..<count {
            let key = ctx.keyString(i)
            out[key] = try V.__adjsonDecode(_FastDecodeCursor(ctx: ctx, index: i + 1))
            i = ctx.nextIndex(after: i + 1)
        }
        return out
    }

    @usableFromInline func mismatch(_ type: Any.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: [], debugDescription: "Expected \(type)"))
    }
}
