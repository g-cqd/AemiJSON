public import ADJSONCore

extension JSONValue {
    /// Encodes any `Encodable` directly into a `JSONValue` tree — the structural counterpart of
    /// decoding through ``JSONValueDecoder``, and the symmetric partner of ``init(parsing:options:)``.
    ///
    /// This is a single pass with **no byte serialization** (unlike encode-then-parse). It uses
    /// default `Codable` semantics and does **not** apply `Date` / `Data` / key-name strategies — use
    /// ``ADJSON/JSONEncoder/encode(_:)`` when those matter. Integers within `Int64` are held as
    /// ``int(_:)``; a `UInt64` above `Int64.max` becomes ``number(_:)`` (lossy above 2^53), matching
    /// the value model.
    public init<Value: Encodable>(encoding value: Value) throws {
        let encoder = JSONValueEncoderImpl(codingPath: [])
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

/// `CodingKey` for array positions, used only to build `codingPath` in error contexts.
private struct IndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { "Index \(intValue ?? 0)" }
    init(_ i: Int) { intValue = i }
    init?(intValue: Int) { self.intValue = intValue }
    init?(stringValue: String) { nil }
}

// MARK: - Encoder

private final class JSONValueEncoderImpl: Encoder {
    var codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]
    let slot: Slot

    init(codingPath: [CodingKey], slot: Slot = Slot()) {
        self.codingPath = codingPath
        self.slot = slot
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
        return KeyedEncodingContainer(KeyedContainer<Key>(object: object, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let array: RefArray
        if case .array(let existing) = slot.kind {
            array = existing
        } else {
            array = RefArray()
            slot.kind = .array(array)
        }
        return UnkeyedContainer(array: array, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        SingleValueContainer(slot: slot, codingPath: codingPath)
    }
}

// MARK: - Single value

private struct SingleValueContainer: SingleValueEncodingContainer {
    let slot: Slot
    var codingPath: [CodingKey]

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
        try value.encode(to: JSONValueEncoderImpl(codingPath: codingPath, slot: slot))
    }
}

// MARK: - Keyed

private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let object: RefObject
    var codingPath: [CodingKey]

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
        try value.encode(to: JSONValueEncoderImpl(codingPath: codingPath + [key], slot: slot(key)))
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let object = RefObject()
        slot(key).kind = .object(object)
        return KeyedEncodingContainer(KeyedContainer<NestedKey>(object: object, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let array = RefArray()
        slot(key).kind = .array(array)
        return UnkeyedContainer(array: array, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> Encoder {
        JSONValueEncoderImpl(codingPath: codingPath, slot: object.slot(forKey: "super"))
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        JSONValueEncoderImpl(codingPath: codingPath + [key], slot: slot(key))
    }
}

// MARK: - Unkeyed

private struct UnkeyedContainer: UnkeyedEncodingContainer {
    let array: RefArray
    var codingPath: [CodingKey]
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
        try value.encode(to: JSONValueEncoderImpl(codingPath: codingPath + [key], slot: appendSlot()))
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let key = nextIndexKey
        let object = RefObject()
        appendSlot().kind = .object(object)
        return KeyedEncodingContainer(KeyedContainer<NestedKey>(object: object, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let key = nextIndexKey
        let inner = RefArray()
        appendSlot().kind = .array(inner)
        return UnkeyedContainer(array: inner, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> Encoder {
        JSONValueEncoderImpl(codingPath: codingPath, slot: appendSlot())
    }
}
