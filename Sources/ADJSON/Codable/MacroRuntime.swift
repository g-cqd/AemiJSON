import Foundation

// ============================================================================
// MACRO RUNTIME — SPI (not API). The public-underscored symbols here
// (`_FastDecodeCursor`, `_FastEncodeWriter`, `__adjsonDecode`, `__adjsonEncode`,
// `ADJSONFast*`) exist only for code emitted by the `@JSONCodable` macro and for
// hand-written fast conformances. They are intentionally underscored to signal
// "do not call directly": a macro cannot inject an `@_spi` import into the user's
// file, so public-underscored is the idiomatic way to expose a macro runtime.
// Treat as unstable; use `@JSONCodable` instead.
// ============================================================================

// Opt-in fast paths that bypass the Codable container protocols. The generic
// decoder/encoder dispatch to them when a value type opts in, so even `[User]` /
// nested types benefit.

public protocol ADJSONFastDecodable {
    static func __adjsonDecode(_ cursor: _FastDecodeCursor) throws -> Self
}

public protocol ADJSONFastEncodable {
    func __adjsonEncode(into writer: _FastEncodeWriter) throws
}

struct StaticCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ s: StaticString) { stringValue = s.description }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension DecodeContext {
    /// Value-slot index for a statically-known key, matched on raw bytes (no String
    /// alloc). Returns the LAST match (duplicate keys resolve last-value-wins).
    func memberValueIndex(of obj: Int, keyBytes lit: StaticString) -> Int? {
        let c = Slot.count(tape[obj])
        var i = obj + 1
        let target = lit.utf8Start
        let tlen = lit.utf8CodeUnitCount
        var found: Int? = nil
        for _ in 0..<c {
            let ks = tape[i]
            let valIdx = i + 1
            let koff = Slot.low(ks), klen = Slot.length(ks)
            if Slot.flags(ks) & 1 == 0 {
                if klen == tlen && (tlen == 0 || memcmp(bytes + koff, target, tlen) == 0) { found = valIdx }
            } else if unescapeString(bytes, koff, klen) == lit.description {
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
    let ctx: DecodeContext
    let index: Int

    init(ctx: DecodeContext, index: Int) {
        self.ctx = ctx
        self.index = index
    }

    public func string(_ key: StaticString) throws -> String {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), let s = ctx.string(vi) else {
            throw missing(key)
        }
        return s
    }

    public func stringIfPresent(_ key: StaticString) -> String? {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), !ctx.isNull(vi) else { return nil }
        return ctx.string(vi)
    }

    public func bool(_ key: StaticString) throws -> Bool {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), let b = ctx.bool(vi) else { throw missing(key) }
        return b
    }

    public func boolIfPresent(_ key: StaticString) -> Bool? {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), !ctx.isNull(vi) else { return nil }
        return ctx.bool(vi)
    }

    public func double(_ key: StaticString) throws -> Double {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), let d = ctx.double(vi) else {
            throw missing(key)
        }
        return d
    }

    public func doubleIfPresent(_ key: StaticString) -> Double? {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), !ctx.isNull(vi) else { return nil }
        return ctx.double(vi)
    }

    public func integer<T: FixedWidthInteger>(_ key: StaticString, _ type: T.Type) throws -> T {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), let n = ctx.integer(vi, type) else {
            throw missing(key)
        }
        return n
    }

    public func integerIfPresent<T: FixedWidthInteger>(_ key: StaticString, _ type: T.Type) -> T? {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), !ctx.isNull(vi) else { return nil }
        return ctx.integer(vi, type)
    }

    public func decode<T: Decodable>(_ type: T.Type, _ key: StaticString) throws -> T {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key) else { throw missing(key) }
        return try ctx.decodeValue(type, at: vi)
    }

    public func decodeIfPresent<T: Decodable>(_ type: T.Type, _ key: StaticString) throws -> T? {
        guard let vi = ctx.memberValueIndex(of: index, keyBytes: key), !ctx.isNull(vi) else { return nil }
        return try ctx.decodeValue(type, at: vi)
    }

    private func missing(_ key: StaticString) -> DecodingError {
        .keyNotFound(StaticCodingKey(key), .init(codingPath: [], debugDescription: "No value for key \(key)"))
    }
}

extension _FastDecodeCursor {
    /// Decode an array whose elements opt into the fast path, with no generic
    /// unkeyed container / existential boxing per element.
    public func fastArray<U: ADJSONFastDecodable>(_ type: U.Type) throws -> [U] {
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
}

// Conditional conformances make `[FastType]` / `FastType?` themselves fast, so a
// top-level array or an optional field skips Codable's collection machinery.
extension Array: ADJSONFastDecodable where Element: ADJSONFastDecodable {
    public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> [Element] {
        try c.fastArray(Element.self)
    }
}

extension Array: ADJSONFastEncodable where Element: ADJSONFastEncodable {
    public func __adjsonEncode(into w: _FastEncodeWriter) throws {
        w.beginArray()
        var first = true
        for e in self {
            if first { first = false } else { w.comma() }
            try e.__adjsonEncode(into: w)
        }
        w.endArray()
    }
}

// MARK: Built-in fast conformances for scalars / Optional / Dictionary, so arrays,
// optionals, and string-keyed dictionaries of these are fast too (no generic fallback).

extension _FastDecodeCursor {
    public func currentString() throws -> String {
        guard let s = ctx.string(index) else { throw mismatch(String.self) }
        return s
    }
    public func currentBool() throws -> Bool {
        guard let b = ctx.bool(index) else { throw mismatch(Bool.self) }
        return b
    }
    public func currentDouble() throws -> Double {
        guard let d = ctx.double(index) else { throw mismatch(Double.self) }
        return d
    }
    public func currentInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard let n = ctx.integer(index, type) else { throw mismatch(T.self) }
        return n
    }
    public var currentIsNull: Bool { ctx.isNull(index) }

    /// Decode an object whose values opt into the fast path into `[String: V]`.
    public func fastDictionary<V: ADJSONFastDecodable>(_ type: V.Type) throws -> [String: V] {
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

    func mismatch(_ type: Any.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: [], debugDescription: "Expected \(type)"))
    }
}

extension String: ADJSONFastDecodable {
    public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> String { try c.currentString() }
}
extension String: ADJSONFastEncodable {
    public func __adjsonEncode(into w: _FastEncodeWriter) { w.string(self) }
}
extension Bool: ADJSONFastDecodable {
    public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Bool { try c.currentBool() }
}
extension Bool: ADJSONFastEncodable {
    public func __adjsonEncode(into w: _FastEncodeWriter) { w.bool(self) }
}
extension Double: ADJSONFastDecodable {
    public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Double { try c.currentDouble() }
}
extension Double: ADJSONFastEncodable {
    public func __adjsonEncode(into w: _FastEncodeWriter) throws { try w.double(self) }
}
extension Float: ADJSONFastDecodable {
    public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Float { Float(try c.currentDouble()) }
}
extension Float: ADJSONFastEncodable {
    public func __adjsonEncode(into w: _FastEncodeWriter) throws { try w.double(Double(self)) }
}

extension ADJSONFastDecodable where Self: FixedWidthInteger {
    public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self { try c.currentInteger(Self.self) }
}
extension ADJSONFastEncodable where Self: FixedWidthInteger {
    public func __adjsonEncode(into w: _FastEncodeWriter) { w.integer(self) }
}
extension Int: ADJSONFastDecodable {}
extension Int: ADJSONFastEncodable {}
extension Int8: ADJSONFastDecodable {}
extension Int8: ADJSONFastEncodable {}
extension Int16: ADJSONFastDecodable {}
extension Int16: ADJSONFastEncodable {}
extension Int32: ADJSONFastDecodable {}
extension Int32: ADJSONFastEncodable {}
extension Int64: ADJSONFastDecodable {}
extension Int64: ADJSONFastEncodable {}
extension UInt: ADJSONFastDecodable {}
extension UInt: ADJSONFastEncodable {}
extension UInt8: ADJSONFastDecodable {}
extension UInt8: ADJSONFastEncodable {}
extension UInt16: ADJSONFastDecodable {}
extension UInt16: ADJSONFastEncodable {}
extension UInt32: ADJSONFastDecodable {}
extension UInt32: ADJSONFastEncodable {}
extension UInt64: ADJSONFastDecodable {}
extension UInt64: ADJSONFastEncodable {}

extension Optional: ADJSONFastDecodable where Wrapped: ADJSONFastDecodable {
    public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Wrapped? {
        c.currentIsNull ? nil : try Wrapped.__adjsonDecode(c)
    }
}
extension Optional: ADJSONFastEncodable where Wrapped: ADJSONFastEncodable {
    public func __adjsonEncode(into w: _FastEncodeWriter) throws {
        if let value = self { try value.__adjsonEncode(into: w) } else { w.null() }
    }
}

extension Dictionary: ADJSONFastDecodable where Key == String, Value: ADJSONFastDecodable {
    public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> [String: Value] {
        try c.fastDictionary(Value.self)
    }
}
extension Dictionary: ADJSONFastEncodable where Key == String, Value: ADJSONFastEncodable {
    public func __adjsonEncode(into w: _FastEncodeWriter) throws {
        w.beginObject()
        var first = true
        for (key, value) in self {
            if first { first = false } else { w.comma() }
            w.dynamicKey(key)
            try value.__adjsonEncode(into: w)
        }
        w.endObject()
    }
}

extension DecodeContext {
    /// Decode any Decodable at a tape index — fast path if the type opts in, else
    /// the generic container path. The fast-path result is bound back to `T` with a
    /// conditional cast (the conformer is `T` by construction); if that ever failed
    /// we fall through to the generic decoder rather than trap.
    func decodeValue<T: Decodable>(_ type: T.Type, at index: Int) throws -> T {
        if let fast = T.self as? any ADJSONFastDecodable.Type {
            if let value = try fast.__adjsonDecode(_FastDecodeCursor(ctx: self, index: index)) as? T {
                return value
            }
        }
        return try T(from: TapeDecoder(ctx: self, index: index, codingPath: []))
    }
}

/// Writes JSON directly into the shared buffer. Handed to generated `__adjsonEncode`,
/// which manages braces/commas explicitly (no frame stack).
public struct _FastEncodeWriter {
    let w: JSONWriter

    init(_ w: JSONWriter) { self.w = w }

    public func beginObject() { w.byte(0x7B) }
    public func endObject() { w.byte(0x7D) }
    public func beginArray() { w.byte(0x5B) }
    public func endArray() { w.byte(0x5D) }
    public func comma() { w.byte(0x2C) }
    public func key(_ k: StaticString) {
        w.byte(0x22)
        w.raw(k)
        w.byte(0x22)
        w.byte(0x3A)
    }
    public func string(_ v: String) { w.writeString(v) }
    /// A runtime (non-static) object key, escaped. Used for `Dictionary` keys.
    public func dynamicKey(_ k: String) { w.writeKey(k) }
    public func integer<T: FixedWidthInteger>(_ v: T) { w.writeInteger(v) }
    public func bool(_ v: Bool) { w.writeBool(v) }
    public func null() { w.writeNull() }

    public func double(_ v: Double) throws {
        guard v.isFinite else {
            throw EncodingError.invalidValue(
                v, .init(codingPath: [], debugDescription: "Non-finite \(v) cannot be encoded as JSON"))
        }
        w.writeDouble(v)
    }

    public func encode<T: Encodable>(_ v: T) throws {
        if let fast = v as? ADJSONFastEncodable {
            try fast.__adjsonEncode(into: self)
        } else {
            let state = EncodeState(w)
            try v.encode(to: TapeEncoder(state: state))
            state.closeDownTo(0)
        }
    }
}
