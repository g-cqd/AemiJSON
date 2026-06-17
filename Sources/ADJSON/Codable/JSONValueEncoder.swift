public import ADJSONCore

extension JSONValue {
    /// Encodes any `Encodable` directly into a `JSONValue` tree — the structural counterpart of
    /// decoding through ``ADJSON/JSONDecoder``, and the symmetric partner of ``init(parsing:options:)``.
    ///
    /// This is a single pass with **no byte serialization** (unlike encode-then-parse). It uses
    /// default `Codable` semantics and does **not** apply `Date` / `Data` / key-name strategies — use
    /// ``ADJSON/JSONEncoder/encode(_:)`` when those matter. Integers within `Int64` are held as
    /// ``/ADJSONCore/JSONValue/int(_:)``; a `UInt64` above `Int64.max` becomes
    /// ``/ADJSONCore/JSONValue/number(_:)`` (lossy above 2^53), matching the value model.
    ///
    /// `maxDepth` bounds the (unavoidably recursive) encode so a self-referential or pathologically
    /// deep `Encodable` throws `EncodingError` rather than overflowing the native stack. The default
    /// (2048) is sized for the ~8 MB main thread; lower it when encoding untrusted graphs on a
    /// small-stack worker thread.
    public init<Value: Encodable>(encoding value: Value, maxDepth: Int = 2048) throws {
        let encoder = JSONValueEncoderImpl(codingPath: [], maxDepth: maxDepth)
        try value.encode(to: encoder)
        self = encoder.finalValue
    }
}

// MARK: - Slot tree
//
// Containers write into shared reference slots so a parent observes everything its nested
// containers and sub-encoders produce. `resolve()` then folds the slot tree into a `JSONValue`.

private final class Slot {
    enum Kind {
        case value(JSONValue)
        case object(RefObject)
        case array(RefArray)
    }
    var kind: Kind = .value(.null)

    func resolve() -> JSONValue {
        switch kind {
        case .value(let v): return v
        case .object(let o): return .object(o.resolve())
        case .array(let a): return .array(a.resolve())
        }
    }
}

private final class RefObject {
    var members = OrderedDictionary<String, Slot>()
    /// Last-writer-wins per key, matching `Codable`'s repeated-`encode(forKey:)` semantics.
    func slot(forKey key: String) -> Slot {
        if let existing = members[key] { return existing }
        let s = Slot()
        members[key] = s
        return s
    }
    func resolve() -> OrderedDictionary<String, JSONValue> {
        var out = OrderedDictionary<String, JSONValue>(minimumCapacity: members.count)
        for (key, slot) in members { out[key] = slot.resolve() }
        return out
    }
}

private final class RefArray {
    var slots: [Slot] = []
    func newSlot() -> Slot {
        let s = Slot()
        slots.append(s)
        return s
    }
    func resolve() -> [JSONValue] { slots.map { $0.resolve() } }
}

/// Maps any binary integer to the value model: exact within `Int64` ⇒ `.int`, otherwise `.number`.
private func jsonNumber<T: BinaryInteger>(_ v: T) -> JSONValue {
    if let i = Int64(exactly: v) { return .int(i) }
    return .number(Double(v))
}

// MARK: - Encoder

// Recursion-depth budget for `JSONValue(encoding:)`. The encode is unavoidably recursive
// (`encode<T>` → `value.encode(to: child)`), so a self-referential or pathologically deep
// `Encodable` would overflow the native stack; past this it throws `EncodingError` and fails closed.
// Symmetric with ``ADJSON/JSONEncoder/maxEncodingDepth`` (default 2048, sized for the ~8 MB main thread).
private let jsonValueEncodeMaxDepth = 2048

// Throwing guard for the recursive `encode<T>` sites. The non-throwing container requirements
// (`nestedContainer`, `superEncoder`) can't throw, so they instead hand the child a `depth + 1`
// encoder — any nested `encode<T>` reached through them still trips this guard. Mirrors the tape
// encoder's `EncodeState.encodeValue` guard.
@inline(__always)
private func guardEncodeDepth(_ depth: Int, _ maxDepth: Int, _ value: Any, _ codingPath: [any CodingKey]) throws {
    guard depth < maxDepth else {
        throw EncodingError.invalidValue(
            value,
            .init(
                codingPath: codingPath,
                debugDescription: "Encoding exceeded the maximum nesting depth (\(maxDepth))"))
    }
}

private final class JSONValueEncoderImpl: Encoder {
    var codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]
    let slot: Slot
    let depth: Int
    let maxDepth: Int

    init(codingPath: [any CodingKey], slot: Slot = Slot(), depth: Int = 0, maxDepth: Int = jsonValueEncodeMaxDepth) {
        self.codingPath = codingPath
        self.slot = slot
        self.depth = depth
        self.maxDepth = maxDepth
    }

    var finalValue: JSONValue { slot.resolve() }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let object: RefObject
        if case .object(let existing) = slot.kind {
            object = existing
        } else {
            object = RefObject()
            slot.kind = .object(object)
        }
        return KeyedEncodingContainer(
            KeyedContainer<Key>(object: object, codingPath: codingPath, depth: depth, maxDepth: maxDepth))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        let array: RefArray
        if case .array(let existing) = slot.kind {
            array = existing
        } else {
            array = RefArray()
            slot.kind = .array(array)
        }
        return UnkeyedContainer(array: array, codingPath: codingPath, depth: depth, maxDepth: maxDepth)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleValueContainer(slot: slot, codingPath: codingPath, depth: depth, maxDepth: maxDepth)
    }
}

// MARK: - Single value

private struct SingleValueContainer: SingleValueEncodingContainer {
    let slot: Slot
    var codingPath: [any CodingKey]
    let depth: Int
    let maxDepth: Int

    mutating func encodeNil() { slot.kind = .value(.null) }
    mutating func encode(_ value: Bool) { slot.kind = .value(.bool(value)) }
    mutating func encode(_ value: String) { slot.kind = .value(.string(value)) }
    mutating func encode(_ value: Double) { slot.kind = .value(.number(value)) }
    mutating func encode(_ value: Float) { slot.kind = .value(.number(Double(value))) }
    mutating func encode(_ value: Int) { slot.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int8) { slot.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int16) { slot.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int32) { slot.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int64) { slot.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt) { slot.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt8) { slot.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt16) { slot.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt32) { slot.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt64) { slot.kind = .value(jsonNumber(value)) }
    mutating func encode<T: Encodable>(_ value: T) throws {
        try guardEncodeDepth(depth, maxDepth, value, codingPath)
        try value.encode(
            to: JSONValueEncoderImpl(codingPath: codingPath, slot: slot, depth: depth + 1, maxDepth: maxDepth))
    }
}

// MARK: - Keyed

private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let object: RefObject
    var codingPath: [any CodingKey]
    let depth: Int
    let maxDepth: Int

    private func slot(_ key: Key) -> Slot { object.slot(forKey: key.stringValue) }

    mutating func encodeNil(forKey key: Key) { slot(key).kind = .value(.null) }
    mutating func encode(_ value: Bool, forKey key: Key) { slot(key).kind = .value(.bool(value)) }
    mutating func encode(_ value: String, forKey key: Key) { slot(key).kind = .value(.string(value)) }
    mutating func encode(_ value: Double, forKey key: Key) { slot(key).kind = .value(.number(value)) }
    mutating func encode(_ value: Float, forKey key: Key) { slot(key).kind = .value(.number(Double(value))) }
    mutating func encode(_ value: Int, forKey key: Key) { slot(key).kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int8, forKey key: Key) { slot(key).kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int16, forKey key: Key) { slot(key).kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int32, forKey key: Key) { slot(key).kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int64, forKey key: Key) { slot(key).kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt, forKey key: Key) { slot(key).kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt8, forKey key: Key) { slot(key).kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt16, forKey key: Key) { slot(key).kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt32, forKey key: Key) { slot(key).kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt64, forKey key: Key) { slot(key).kind = .value(jsonNumber(value)) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try guardEncodeDepth(depth, maxDepth, value, codingPath + [key])
        try value.encode(
            to: JSONValueEncoderImpl(
                codingPath: codingPath + [key], slot: slot(key), depth: depth + 1, maxDepth: maxDepth))
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let object = RefObject()
        slot(key).kind = .object(object)
        return KeyedEncodingContainer(
            KeyedContainer<NestedKey>(
                object: object, codingPath: codingPath + [key], depth: depth + 1, maxDepth: maxDepth))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        let array = RefArray()
        slot(key).kind = .array(array)
        return UnkeyedContainer(array: array, codingPath: codingPath + [key], depth: depth + 1, maxDepth: maxDepth)
    }

    mutating func superEncoder() -> any Encoder {
        JSONValueEncoderImpl(
            codingPath: codingPath, slot: object.slot(forKey: "super"), depth: depth + 1, maxDepth: maxDepth)
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        JSONValueEncoderImpl(codingPath: codingPath + [key], slot: slot(key), depth: depth + 1, maxDepth: maxDepth)
    }
}

// MARK: - Unkeyed

private struct UnkeyedContainer: UnkeyedEncodingContainer {
    let array: RefArray
    var codingPath: [any CodingKey]
    let depth: Int
    let maxDepth: Int
    var count: Int { array.slots.count }

    private func appendSlot() -> Slot { array.newSlot() }
    private var nextIndexKey: IndexKey { IndexKey(array.slots.count) }

    mutating func encodeNil() { appendSlot().kind = .value(.null) }
    mutating func encode(_ value: Bool) { appendSlot().kind = .value(.bool(value)) }
    mutating func encode(_ value: String) { appendSlot().kind = .value(.string(value)) }
    mutating func encode(_ value: Double) { appendSlot().kind = .value(.number(value)) }
    mutating func encode(_ value: Float) { appendSlot().kind = .value(.number(Double(value))) }
    mutating func encode(_ value: Int) { appendSlot().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int8) { appendSlot().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int16) { appendSlot().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int32) { appendSlot().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int64) { appendSlot().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt) { appendSlot().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt8) { appendSlot().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt16) { appendSlot().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt32) { appendSlot().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt64) { appendSlot().kind = .value(jsonNumber(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let key = nextIndexKey
        try guardEncodeDepth(depth, maxDepth, value, codingPath + [key])
        try value.encode(
            to: JSONValueEncoderImpl(
                codingPath: codingPath + [key], slot: appendSlot(), depth: depth + 1, maxDepth: maxDepth))
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let key = nextIndexKey
        let object = RefObject()
        appendSlot().kind = .object(object)
        return KeyedEncodingContainer(
            KeyedContainer<NestedKey>(
                object: object, codingPath: codingPath + [key], depth: depth + 1, maxDepth: maxDepth))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let key = nextIndexKey
        let inner = RefArray()
        appendSlot().kind = .array(inner)
        return UnkeyedContainer(array: inner, codingPath: codingPath + [key], depth: depth + 1, maxDepth: maxDepth)
    }

    mutating func superEncoder() -> any Encoder {
        JSONValueEncoderImpl(codingPath: codingPath, slot: appendSlot(), depth: depth + 1, maxDepth: maxDepth)
    }
}
