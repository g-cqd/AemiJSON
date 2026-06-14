import Foundation

// Direct-streaming Encoder: writes JSON straight into one shared JSONWriter as
// `encode(to:)` runs — no reference tree, no value tree. Containers are closed
// lazily: before writing a member at frame depth `d`, any still-open deeper
// frames (completed children) are closed. Assumes well-behaved sequential,
// properly-nested Codable usage (universal for synthesized + hand-written
// conformances); does not rely on `deinit`.
final class EncodeState {
    let w: JSONWriter
    let options: JSONEncodingOptions
    var kinds: [Bool] = []  // true = object, false = array
    var counts: [Int] = []

    init(_ w: JSONWriter, options: JSONEncodingOptions = .rfc8259) {
        self.w = w
        self.options = options
    }

    @inline(__always) func appendDouble(_ v: Double) throws {
        try JSONOutput.appendDouble(v, options: options, to: &w.bytes)
    }

    @inline(__always) func open(object: Bool) -> Int {
        w.byte(object ? 0x7B : 0x5B)
        kinds.append(object)
        counts.append(0)
        return kinds.count - 1
    }

    @inline(__always) func closeDownTo(_ target: Int) {
        while kinds.count > target {
            let isObject = kinds.removeLast()
            counts.removeLast()
            w.byte(isObject ? 0x7D : 0x5D)
        }
    }

    @inline(__always) func beginMember(_ frame: Int) {
        closeDownTo(frame + 1)
        if counts[frame] > 0 { w.byte(0x2C) }
        counts[frame] += 1
    }

    /// Bridge a fast-path value nested inside a generic encode: move the shared buffer
    /// into a value `JSONByteWriter` (so its appends don't trigger CoW), then move back.
    @inline(__always) func encodeFast(_ fast: any ADJSONFastEncodable) throws {
        var bw = JSONByteWriter(adopting: w.bytes, options: options)
        w.bytes = []
        try fast.__adjsonEncode(into: &bw)
        w.bytes = bw.bytes
    }
}

struct TapeEncoder: Encoder {
    let state: EncodeState
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let frame = state.open(object: true)
        return KeyedEncodingContainer(KeyedTapeEncodingContainer<Key>(state: state, frame: frame))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        let frame = state.open(object: false)
        return UnkeyedTapeEncodingContainer(state: state, frame: frame)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleValueTapeEncodingContainer(state: state)
    }
}

// MARK: - Keyed

private struct KeyedTapeEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let state: EncodeState
    let frame: Int
    var codingPath: [any CodingKey] { [] }

    @inline(__always) func member(_ key: Key) {
        state.beginMember(frame)
        state.w.writeKey(key.stringValue)
    }

    mutating func encodeNil(forKey key: Key) {
        member(key)
        state.w.writeNull()
    }
    mutating func encode(_ v: Bool, forKey key: Key) {
        member(key)
        state.w.writeBool(v)
    }
    mutating func encode(_ v: String, forKey key: Key) {
        member(key)
        state.w.writeString(v)
    }
    mutating func encode(_ v: Double, forKey key: Key) throws {
        member(key)
        try state.appendDouble(v)
    }
    mutating func encode(_ v: Float, forKey key: Key) throws {
        member(key)
        try state.appendDouble(Double(v))
    }
    mutating func encode(_ v: Int, forKey key: Key) {
        member(key)
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: Int8, forKey key: Key) {
        member(key)
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: Int16, forKey key: Key) {
        member(key)
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: Int32, forKey key: Key) {
        member(key)
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: Int64, forKey key: Key) {
        member(key)
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: UInt, forKey key: Key) {
        member(key)
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: UInt8, forKey key: Key) {
        member(key)
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: UInt16, forKey key: Key) {
        member(key)
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: UInt32, forKey key: Key) {
        member(key)
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: UInt64, forKey key: Key) {
        member(key)
        state.w.writeInteger(v)
    }

    mutating func encode<T: Encodable>(_ v: T, forKey key: Key) throws {
        member(key)
        if let fast = v as? any ADJSONFastEncodable {
            try state.encodeFast(fast)
        } else {
            try v.encode(to: TapeEncoder(state: state))
        }
    }

    mutating func nestedContainer<NK: CodingKey>(
        keyedBy keyType: NK.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NK> {
        member(key)
        let f = state.open(object: true)
        return KeyedEncodingContainer(KeyedTapeEncodingContainer<NK>(state: state, frame: f))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        member(key)
        let f = state.open(object: false)
        return UnkeyedTapeEncodingContainer(state: state, frame: f)
    }

    mutating func superEncoder() -> any Encoder { TapeEncoder(state: state) }
    mutating func superEncoder(forKey key: Key) -> any Encoder {
        member(key)
        return TapeEncoder(state: state)
    }
}

// MARK: - Unkeyed

private struct UnkeyedTapeEncodingContainer: UnkeyedEncodingContainer {
    let state: EncodeState
    let frame: Int
    var codingPath: [any CodingKey] { [] }
    var count: Int { state.counts[frame] }

    @inline(__always) func elem() { state.beginMember(frame) }

    mutating func encodeNil() {
        elem()
        state.w.writeNull()
    }
    mutating func encode(_ v: Bool) {
        elem()
        state.w.writeBool(v)
    }
    mutating func encode(_ v: String) {
        elem()
        state.w.writeString(v)
    }
    mutating func encode(_ v: Double) throws {
        elem()
        try state.appendDouble(v)
    }
    mutating func encode(_ v: Float) throws {
        elem()
        try state.appendDouble(Double(v))
    }
    mutating func encode(_ v: Int) {
        elem()
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: Int8) {
        elem()
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: Int16) {
        elem()
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: Int32) {
        elem()
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: Int64) {
        elem()
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: UInt) {
        elem()
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: UInt8) {
        elem()
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: UInt16) {
        elem()
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: UInt32) {
        elem()
        state.w.writeInteger(v)
    }
    mutating func encode(_ v: UInt64) {
        elem()
        state.w.writeInteger(v)
    }

    mutating func encode<T: Encodable>(_ v: T) throws {
        elem()
        if let fast = v as? any ADJSONFastEncodable {
            try state.encodeFast(fast)
        } else {
            try v.encode(to: TapeEncoder(state: state))
        }
    }

    mutating func nestedContainer<NK: CodingKey>(keyedBy keyType: NK.Type) -> KeyedEncodingContainer<NK> {
        elem()
        let f = state.open(object: true)
        return KeyedEncodingContainer(KeyedTapeEncodingContainer<NK>(state: state, frame: f))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        elem()
        let f = state.open(object: false)
        return UnkeyedTapeEncodingContainer(state: state, frame: f)
    }

    mutating func superEncoder() -> any Encoder {
        elem()
        return TapeEncoder(state: state)
    }
}

// MARK: - Single value

private struct SingleValueTapeEncodingContainer: SingleValueEncodingContainer {
    let state: EncodeState
    var codingPath: [any CodingKey] { [] }

    mutating func encodeNil() { state.w.writeNull() }
    mutating func encode(_ v: Bool) { state.w.writeBool(v) }
    mutating func encode(_ v: String) { state.w.writeString(v) }
    mutating func encode(_ v: Double) throws {
        try state.appendDouble(v)
    }
    mutating func encode(_ v: Float) throws {
        try state.appendDouble(Double(v))
    }
    mutating func encode(_ v: Int) { state.w.writeInteger(v) }
    mutating func encode(_ v: Int8) { state.w.writeInteger(v) }
    mutating func encode(_ v: Int16) { state.w.writeInteger(v) }
    mutating func encode(_ v: Int32) { state.w.writeInteger(v) }
    mutating func encode(_ v: Int64) { state.w.writeInteger(v) }
    mutating func encode(_ v: UInt) { state.w.writeInteger(v) }
    mutating func encode(_ v: UInt8) { state.w.writeInteger(v) }
    mutating func encode(_ v: UInt16) { state.w.writeInteger(v) }
    mutating func encode(_ v: UInt32) { state.w.writeInteger(v) }
    mutating func encode(_ v: UInt64) { state.w.writeInteger(v) }

    mutating func encode<T: Encodable>(_ v: T) throws {
        if let fast = v as? any ADJSONFastEncodable {
            return try state.encodeFast(fast)
        }
        try v.encode(to: TapeEncoder(state: state))
    }
}
