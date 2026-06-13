import Foundation

// A value-type `Decoder` over the tape. No eager dictionary, no key-String
// allocation, no per-node class/ARC churn: keyed lookups match `CodingKey`
// bytes against the tape and skip unread subtrees in O(1). A single shared
// `DecodeContext` holds a stable base pointer for the duration of one decode, so scalar
// access needs no per-value `withUnsafeBufferPointer`.

final class DecodeContext {
    let doc: JSONDocument  // retains backing storage for the decode's lifetime
    let bytes: UnsafePointer<UInt8>
    let tape: UnsafePointer<UInt64>
    let userInfo: [CodingUserInfoKey: Any]

    init(
        doc: JSONDocument, bytes: UnsafePointer<UInt8>, tape: UnsafePointer<UInt64>, userInfo: [CodingUserInfoKey: Any]
    ) {
        self.doc = doc
        self.bytes = bytes
        self.tape = tape
        self.userInfo = userInfo
    }

    @inline(__always) func tag(_ i: Int) -> UInt8 { Slot.tag(tape[i]) }
    @inline(__always) func count(_ i: Int) -> Int { Slot.count(tape[i]) }
    @inline(__always) func isNull(_ i: Int) -> Bool { Slot.tag(tape[i]) == JSONKind.null.rawValue }

    @inline(__always) func nextIndex(after i: Int) -> Int {
        let s = tape[i]
        let t = Slot.tag(s)
        if t == JSONKind.object.rawValue || t == JSONKind.array.rawValue { return Slot.low(s) }
        return i + 1
    }

    @inline(__always) func bool(_ i: Int) -> Bool? {
        switch Slot.tag(tape[i]) {
        case JSONKind.boolTrue.rawValue: return true
        case JSONKind.boolFalse.rawValue: return false
        default: return nil
        }
    }

    @inline(__always) func double(_ i: Int) -> Double? {
        let s = tape[i]
        guard Slot.tag(s) == JSONKind.number.rawValue else { return nil }
        return adParseDouble(bytes, Slot.low(s), Slot.length(s))
    }

    @inline(__always) func integer<T: FixedWidthInteger>(_ i: Int, _ type: T.Type) -> T? {
        let s = tape[i]
        guard Slot.tag(s) == JSONKind.number.rawValue else { return nil }
        return adParseInteger(bytes, Slot.low(s), Slot.length(s), type)
    }

    func string(_ i: Int) -> String? {
        let s = tape[i]
        guard Slot.tag(s) == JSONKind.string.rawValue else { return nil }
        return decodeString(s)
    }

    func keyString(_ i: Int) -> String { decodeString(tape[i]) }

    @inline(__always) private func decodeString(_ s: UInt64) -> String {
        let off = Slot.low(s), len = Slot.length(s)
        if Slot.flags(s) & 1 == 0 {
            return String(decoding: UnsafeBufferPointer(start: bytes + off, count: len), as: UTF8.self)
        }
        return unescapeString(bytes, off, len)
    }

    /// Index of the value slot for `key` within the object at `obj`, or nil.
    // Returns the LAST matching member (duplicate keys resolve last-value-wins,
    // consistent with `JSON.object` and JS / Foundation semantics).
    func memberValueIndex(of obj: Int, key: String) -> Int? {
        let c = Slot.count(tape[obj])
        var i = obj + 1
        var found: Int? = nil
        for _ in 0..<c {
            let ks = tape[i]
            let valIdx = i + 1
            let koff = Slot.low(ks), klen = Slot.length(ks)
            let matched: Bool
            if Slot.flags(ks) & 1 == 1 {
                matched = unescapeString(bytes, koff, klen) == key
            } else {
                matched = key.utf8.elementsEqual(UnsafeBufferPointer(start: bytes + koff, count: klen))
            }
            if matched { found = valIdx }
            i = nextIndex(after: valIdx)
        }
        return found
    }
}

struct TapeDecoder: Decoder {
    let ctx: DecodeContext
    let index: Int
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { ctx.userInfo }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard ctx.tag(index) == JSONKind.object.rawValue else {
            throw DecodingError.typeMismatch(
                [String: Any].self, .init(codingPath: codingPath, debugDescription: "Expected an object"))
        }
        return KeyedDecodingContainer(KeyedTapeDecodingContainer<Key>(ctx: ctx, index: index, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard ctx.tag(index) == JSONKind.array.rawValue else {
            throw DecodingError.typeMismatch(
                [Any].self, .init(codingPath: codingPath, debugDescription: "Expected an array"))
        }
        return UnkeyedTapeDecodingContainer(ctx: ctx, containerIndex: index, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        SingleValueTapeDecodingContainer(ctx: ctx, index: index, codingPath: codingPath)
    }
}

// MARK: - Keyed

private struct KeyedTapeDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let ctx: DecodeContext
    let index: Int
    let codingPath: [CodingKey]

    var allKeys: [Key] {
        var out: [Key] = []
        let c = ctx.count(index)
        out.reserveCapacity(c)
        var i = index + 1
        for _ in 0..<c {
            if let k = Key(stringValue: ctx.keyString(i)) { out.append(k) }
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
        guard let d = ctx.double(vi) else { throw mismatch(type, key) }
        return d
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        let vi = try requireIndex(key)
        guard let d = ctx.double(vi) else { throw mismatch(type, key) }
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

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let vi = try requireIndex(key)
        return try TapeDecoder(ctx: ctx, index: vi, codingPath: codingPath + [key]).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        TapeDecoder(ctx: ctx, index: index, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
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
    let codingPath: [CodingKey]
    let total: Int
    var currentIndex = 0
    var cursor: Int

    init(ctx: DecodeContext, containerIndex: Int, codingPath: [CodingKey]) {
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
    mutating func decode(_ type: Double.Type) throws -> Double { try scalar { c, i in c.double(i) } }
    mutating func decode(_ type: Float.Type) throws -> Float { try scalar { c, i in c.double(i).map(Float.init) } }
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

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard !isAtEnd else { throw end(Any.self) }
        let decoder = TapeDecoder(ctx: ctx, index: cursor, codingPath: codingPath)
        advance()
        return try decoder.unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
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
    let codingPath: [CodingKey]

    func decodeNil() -> Bool { ctx.isNull(index) }

    func decode(_ type: Bool.Type) throws -> Bool { try value(ctx.bool(index), type) }
    func decode(_ type: String.Type) throws -> String { try value(ctx.string(index), type) }
    func decode(_ type: Double.Type) throws -> Double { try value(ctx.double(index), type) }
    func decode(_ type: Float.Type) throws -> Float { try value(ctx.double(index).map(Float.init), type) }
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
