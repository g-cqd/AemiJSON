import ADJSONCore
import Foundation

// A value-type `Decoder` over the tape. No eager dictionary, no key-String
// allocation, no per-node class/ARC churn: keyed lookups match `CodingKey`
// bytes against the tape and skip unread subtrees in O(1). A single shared
// `DecodeContext` holds a stable base pointer for the duration of one decode, so scalar
// access needs no per-value `withUnsafeBufferPointer`.
//
// Unlike the tape parser, lazy navigation, and `JSONValue` materialization — all iterative — this
// decoder is necessarily recursive: the `Decodable` protocol drives nesting by having each value's
// `init(from:)` decode its children, so one native-stack frame per container level is unavoidable.
// That depth equals the document's nesting depth, which the parser caps at `JSONParseOptions.maxDepth`
// (default 512); a document that parses therefore decodes without overflowing the stack, and the
// safety of untrusted input rests on keeping `maxDepth` modest (see `JSONParseOptions.maxDepth`).

@usableFromInline
final class DecodeContext {
    let doc: JSONDocument  // retains backing storage for the decode's lifetime
    @usableFromInline let bytes: UnsafePointer<UInt8>
    @usableFromInline let tape: UnsafePointer<UInt64>
    @usableFromInline let byteCount: Int
    @usableFromInline let tapeCount: Int
    @usableFromInline let keysAreUnique: Bool
    let userInfo: [CodingUserInfoKey: Any]
    let strategies: DecodeStrategies
    var iso8601: ISO8601DateFormatter?  // lazy, single-operation cache

    // INVARIANT: `bytes`/`tape` are borrowed from `doc`'s storage for the duration of one
    // `withBuffers` scope (see Bytes.swift). `doc` is retained here so the storage outlives
    // every read. We use raw pointers rather than `Span` because Codable's `Decoder` must be
    // `Escapable` (a `Span` cannot be stored in this shared context). `slot`/`decodeString`
    // bounds-check every access under `assert`, so debug/test builds trap on any out-of-range
    // index while release builds keep the raw-pointer speed.
    @usableFromInline
    init(
        doc: JSONDocument, bytes: UnsafePointer<UInt8>, byteCount: Int,
        tape: UnsafePointer<UInt64>, tapeCount: Int, userInfo: [CodingUserInfoKey: Any],
        strategies: DecodeStrategies
    ) {
        self.doc = doc
        self.bytes = bytes
        self.byteCount = byteCount
        self.tape = tape
        self.tapeCount = tapeCount
        self.keysAreUnique = doc.keysAreUnique
        self.userInfo = userInfo
        self.strategies = strategies
    }

    /// Bounds-checked tape read (the single choke point for tape navigation).
    @inline(__always) @inlinable func slot(_ i: Int) -> UInt64 {
        assert(i >= 0 && i < tapeCount, "ADJSON: tape index \(i) out of bounds [0, \(tapeCount))")
        return tape[i]
    }

    @inline(__always) @inlinable func assertBytes(_ off: Int, _ len: Int) {
        assert(off >= 0 && len >= 0 && off + len <= byteCount, "ADJSON: byte range out of bounds")
    }

    @inline(__always) @inlinable func tag(_ i: Int) -> UInt8 { Slot.tag(slot(i)) }
    @inline(__always) @inlinable func count(_ i: Int) -> Int { Slot.count(slot(i)) }
    @inline(__always) @inlinable func isNull(_ i: Int) -> Bool { Slot.tag(slot(i)) == JSONKind.null.rawValue }

    @inline(__always) @inlinable func nextIndex(after i: Int) -> Int { Slot.next(after: i, slot(i)) }

    @inline(__always) @inlinable func bool(_ i: Int) -> Bool? {
        switch Slot.tag(slot(i)) {
        case JSONKind.boolTrue.rawValue: return true
        case JSONKind.boolFalse.rawValue: return false
        default: return nil
        }
    }

    @inline(__always) @inlinable func double(_ i: Int) -> Double? {
        let s = slot(i)
        guard Slot.tag(s) == JSONKind.number.rawValue else { return nil }
        assertBytes(Slot.low(s), Slot.length(s))
        return JSONNumber.parseDouble(bytes, Slot.low(s), Slot.length(s))
    }

    @inline(__always) @inlinable func integer<T: FixedWidthInteger>(_ i: Int, _ type: T.Type) -> T? {
        let s = slot(i)
        guard Slot.tag(s) == JSONKind.number.rawValue else { return nil }
        assertBytes(Slot.low(s), Slot.length(s))
        return JSONNumber.parseInteger(bytes, Slot.low(s), Slot.length(s), type)
    }

    @inlinable func string(_ i: Int) -> String? {
        let s = slot(i)
        guard Slot.tag(s) == JSONKind.string.rawValue else { return nil }
        return decodeString(s)
    }

    @inlinable func keyString(_ i: Int) -> String { decodeString(slot(i)) }

    @inline(__always) @usableFromInline func decodeString(_ s: UInt64) -> String {
        let off = Slot.low(s), len = Slot.length(s)
        assertBytes(off, len)
        if Slot.flags(s) & 1 == 0 {
            return String(decoding: UnsafeBufferPointer(start: bytes + off, count: len), as: UTF8.self)
        }
        return JSONString.unescape(bytes, off, len)
    }

    /// Index of the value slot for `key` within the object at `obj`, or nil.
    // Returns the LAST matching member (duplicate keys resolve last-value-wins,
    // consistent with `JSON.object` and JS / Foundation semantics).
    func memberValueIndex(of obj: Int, key: String) -> Int? {
        let c = Slot.count(slot(obj))
        // When a key-decoding strategy is active, each JSON key is converted (e.g. snake_case →
        // camelCase) before comparison — losing the byte-compare fast path, but only while the
        // strategy is set.
        let convert = keyConversionActive
        var i = obj + 1
        var found: Int? = nil
        for _ in 0..<c {
            let ks = slot(i)
            let valIdx = i + 1
            let isMatch: Bool
            if convert {
                isMatch = applyKeyDecoding(keyString(i)) == key
            } else {
                let koff = Slot.low(ks), klen = Slot.length(ks)
                assertBytes(koff, klen)
                isMatch = JSONKey.matches(bytes, koff, klen, escaped: Slot.flags(ks) & 1 == 1, key)
            }
            if isMatch {
                found = valIdx
                if keysAreUnique { break }  // unique keys → first match is the only match
            }
            i = nextIndex(after: valIdx)
        }
        return found
    }
}

struct TapeDecoder: Decoder {
    let ctx: DecodeContext
    let index: Int
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { ctx.userInfo }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard ctx.tag(index) == JSONKind.object.rawValue else {
            throw DecodingError.typeMismatch(
                [String: Any].self, .init(codingPath: codingPath, debugDescription: "Expected an object"))
        }
        return KeyedDecodingContainer(KeyedTapeDecodingContainer<Key>(ctx: ctx, index: index, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard ctx.tag(index) == JSONKind.array.rawValue else {
            throw DecodingError.typeMismatch(
                [Any].self, .init(codingPath: codingPath, debugDescription: "Expected an array"))
        }
        return UnkeyedTapeDecodingContainer(ctx: ctx, containerIndex: index, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleValueTapeDecodingContainer(ctx: ctx, index: index, codingPath: codingPath)
    }
}

// MARK: - Keyed

private struct KeyedTapeDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let ctx: DecodeContext
    let index: Int
    let codingPath: [any CodingKey]

    var allKeys: [Key] {
        var out: [Key] = []
        let c = ctx.count(index)
        out.reserveCapacity(c)
        var i = index + 1
        for _ in 0..<c {
            if let k = Key(stringValue: ctx.applyKeyDecoding(ctx.keyString(i))) { out.append(k) }
            i = ctx.nextIndex(after: i + 1)
        }
        return out
    }

    func contains(_ key: Key) -> Bool { ctx.memberValueIndex(of: index, key: key.stringValue) != nil }

    func decodeNil(forKey key: Key) throws -> Bool {
        let vi = try requireIndex(key)
        return ctx.isNull(vi)
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        let vi = try requireIndex(key)
        guard let b = ctx.bool(vi) else { throw mismatch(type, key) }
        return b
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        let vi = try requireIndex(key)
        guard let s = ctx.string(vi) else { throw mismatch(type, key) }
        return s
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        let vi = try requireIndex(key)
        guard let d = ctx.decodeFloatingPoint(vi) else { throw mismatch(type, key) }
        return d
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        let vi = try requireIndex(key)
        guard let d = ctx.decodeFloatingPoint(vi) else { throw mismatch(type, key) }
        return Float(d)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try integer(type, key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try integer(type, key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try integer(type, key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try integer(type, key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try integer(type, key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try integer(type, key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try integer(type, key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try integer(type, key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try integer(type, key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try integer(type, key) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try ctx.decodeValue(T.self, at: try requireIndex(key))
    }

    func nestedContainer<NK: CodingKey>(keyedBy type: NK.Type, forKey key: Key) throws -> KeyedDecodingContainer<NK> {
        let vi = try requireIndex(key)
        return try TapeDecoder(ctx: ctx, index: vi, codingPath: codingPath + [key]).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        let vi = try requireIndex(key)
        return try TapeDecoder(ctx: ctx, index: vi, codingPath: codingPath + [key]).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        TapeDecoder(ctx: ctx, index: index, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        TapeDecoder(ctx: ctx, index: try requireIndex(key), codingPath: codingPath + [key])
    }

    @inline(__always) private func requireIndex(_ key: Key) throws -> Int {
        guard let vi = ctx.memberValueIndex(of: index, key: key.stringValue) else {
            throw DecodingError.keyNotFound(
                key, .init(codingPath: codingPath, debugDescription: "No value for key \(key.stringValue)"))
        }
        return vi
    }

    @inline(__always) private func integer<T: FixedWidthInteger>(_ type: T.Type, _ key: Key) throws -> T {
        let vi = try requireIndex(key)
        guard let n = ctx.integer(vi, type) else { throw mismatch(type, key) }
        return n
    }

    private func mismatch(_ type: Any.Type, _ key: Key) -> DecodingError {
        DecodingError.typeMismatch(type, .init(codingPath: codingPath + [key], debugDescription: "Expected \(type)"))
    }
}

// MARK: - Unkeyed (no array materialization; walks the tape via a cursor)

private struct UnkeyedTapeDecodingContainer: UnkeyedDecodingContainer {
    let ctx: DecodeContext
    let containerIndex: Int
    let codingPath: [any CodingKey]
    let total: Int
    var currentIndex = 0
    var cursor: Int

    init(ctx: DecodeContext, containerIndex: Int, codingPath: [any CodingKey]) {
        self.ctx = ctx
        self.containerIndex = containerIndex
        self.codingPath = codingPath
        self.total = ctx.count(containerIndex)
        self.cursor = containerIndex + 1
    }

    var count: Int? { total }
    var isAtEnd: Bool { currentIndex >= total }

    @inline(__always) private mutating func advance() {
        cursor = ctx.nextIndex(after: cursor)
        currentIndex += 1
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { throw end(Any?.self) }
        if ctx.isNull(cursor) {
            advance()
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try scalar { c, i in c.bool(i) } }
    mutating func decode(_ type: String.Type) throws -> String { try scalar { c, i in c.string(i) } }
    mutating func decode(_ type: Double.Type) throws -> Double { try scalar { c, i in c.decodeFloatingPoint(i) } }
    mutating func decode(_ type: Float.Type) throws -> Float {
        try scalar { c, i in c.decodeFloatingPoint(i).map(Float.init) }
    }
    mutating func decode(_ type: Int.Type) throws -> Int { try scalar { c, i in c.integer(i, type) } }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try scalar { c, i in c.integer(i, type) } }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try scalar { c, i in c.integer(i, type) } }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try scalar { c, i in c.integer(i, type) } }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try scalar { c, i in c.integer(i, type) } }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try scalar { c, i in c.integer(i, type) } }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try scalar { c, i in c.integer(i, type) } }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try scalar { c, i in c.integer(i, type) } }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try scalar { c, i in c.integer(i, type) } }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try scalar { c, i in c.integer(i, type) } }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard !isAtEnd else { throw end(type) }
        let at = cursor
        advance()
        return try ctx.decodeValue(T.self, at: at)
    }

    mutating func nestedContainer<NK: CodingKey>(keyedBy type: NK.Type) throws -> KeyedDecodingContainer<NK> {
        guard !isAtEnd else { throw end(Any.self) }
        let decoder = TapeDecoder(ctx: ctx, index: cursor, codingPath: codingPath)
        advance()
        return try decoder.container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard !isAtEnd else { throw end(Any.self) }
        let decoder = TapeDecoder(ctx: ctx, index: cursor, codingPath: codingPath)
        advance()
        return try decoder.unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        guard !isAtEnd else { throw end(Any.self) }
        let decoder = TapeDecoder(ctx: ctx, index: cursor, codingPath: codingPath)
        advance()
        return decoder
    }

    @inline(__always) private mutating func scalar<T>(_ extract: (DecodeContext, Int) -> T?) throws -> T {
        guard !isAtEnd else { throw end(T.self) }
        let c = ctx
        let at = cursor
        guard let result = extract(c, at) else {
            throw DecodingError.typeMismatch(
                T.self, .init(codingPath: codingPath, debugDescription: "Expected \(T.self)"))
        }
        advance()
        return result
    }

    private func end(_ type: Any.Type) -> DecodingError {
        DecodingError.valueNotFound(
            type, .init(codingPath: codingPath, debugDescription: "Unkeyed container is at end"))
    }
}

// MARK: - Single value

private struct SingleValueTapeDecodingContainer: SingleValueDecodingContainer {
    let ctx: DecodeContext
    let index: Int
    let codingPath: [any CodingKey]

    func decodeNil() -> Bool { ctx.isNull(index) }

    func decode(_ type: Bool.Type) throws -> Bool { try value(ctx.bool(index), type) }
    func decode(_ type: String.Type) throws -> String { try value(ctx.string(index), type) }
    func decode(_ type: Double.Type) throws -> Double { try value(ctx.decodeFloatingPoint(index), type) }
    func decode(_ type: Float.Type) throws -> Float { try value(ctx.decodeFloatingPoint(index).map(Float.init), type) }
    func decode(_ type: Int.Type) throws -> Int { try value(ctx.integer(index, type), type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try value(ctx.integer(index, type), type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try value(ctx.integer(index, type), type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try value(ctx.integer(index, type), type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try value(ctx.integer(index, type), type) }
    func decode(_ type: UInt.Type) throws -> UInt { try value(ctx.integer(index, type), type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try value(ctx.integer(index, type), type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try value(ctx.integer(index, type), type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try value(ctx.integer(index, type), type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try value(ctx.integer(index, type), type) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try ctx.decodeValue(T.self, at: index)
    }

    private func value<T>(_ v: T?, _ type: Any.Type) throws -> T {
        guard let v else {
            throw DecodingError.typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Expected \(type)"))
        }
        return v
    }
}
