import ADJSONCore
import Foundation

// A `Decoder` over an already-materialized `JSONValue` tree, backing
// `ADJSON.JSONDecoder.decode(_:from: JSONValue)`. It lets a caller that already holds a `JSONValue`
// decode straight into a `Decodable` without the serialize-and-reparse round-trip. This is the generic
// container path — the macro fast path (`_FastDecodeCursor`) is tape-bound and does not apply here —
// but it honors the same Date/Data/key/non-conforming-float strategies and the `maxDecodingDepth`
// guard as the byte/`JSONDocument` decoders, so results match `decode(_:from:)`.

struct JSONValueDecoderImpl: Decoder {
    let value: JSONValue
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    let strategies: DecodeStrategies
    let depth: Int
    let maxDepth: Int

    func child(_ value: JSONValue, _ codingPath: [any CodingKey]) -> JSONValueDecoderImpl {
        JSONValueDecoderImpl(
            value: value, codingPath: codingPath, userInfo: userInfo, strategies: strategies,
            depth: depth + 1, maxDepth: maxDepth)
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let members) = value else {
            throw typeMismatch([String: Any].self, value, codingPath)
        }
        return KeyedDecodingContainer(KeyedValueContainer(decoder: self, object: members))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let elements) = value else { throw typeMismatch([Any].self, value, codingPath) }
        return UnkeyedValueContainer(decoder: self, elements: elements)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleValueValueContainer(decoder: self, value: value)
    }

    // MARK: - Unboxing

    func unbox<T: Decodable>(_ value: JSONValue, as type: T.Type, _ codingPath: [any CodingKey]) throws -> T {
        // Conditional cast (never a force cast): the metatype guard guarantees the type matches, so it
        // always succeeds and satisfies the shipped-library no-force rule; the else is unreachable.
        if type == Date.self {
            guard let date = try unboxDate(value, codingPath) as? T else { throw typeMismatch(type, value, codingPath) }
            return date
        }
        if type == Data.self {
            guard let data = try unboxData(value, codingPath) as? T else { throw typeMismatch(type, value, codingPath) }
            return data
        }
        guard depth < maxDepth else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: codingPath,
                    debugDescription: "Decoding exceeded the maximum nesting depth (\(maxDepth))"))
        }
        return try T(from: child(value, codingPath))
    }

    func unboxBool(_ value: JSONValue, _ codingPath: [any CodingKey]) throws -> Bool {
        guard case .bool(let b) = value else { throw typeMismatch(Bool.self, value, codingPath) }
        return b
    }

    func unboxString(_ value: JSONValue, _ codingPath: [any CodingKey]) throws -> String {
        guard case .string(let s) = value else { throw typeMismatch(String.self, value, codingPath) }
        return s
    }

    func unboxDouble(_ value: JSONValue, _ codingPath: [any CodingKey]) throws -> Double {
        switch value {
        case .number(let d): return d
        case .int(let i): return Double(i)
        case .string(let s):
            if case let .convertFromString(pos, neg, nan) = strategies.nonConformingFloat {
                if s == pos { return .infinity }
                if s == neg { return -.infinity }
                if s == nan { return .nan }
            }
            throw typeMismatch(Double.self, value, codingPath)
        default:
            throw typeMismatch(Double.self, value, codingPath)
        }
    }

    func unboxFloat(_ value: JSONValue, _ codingPath: [any CodingKey]) throws -> Float {
        Float(try unboxDouble(value, codingPath))
    }

    func unboxInteger<I: FixedWidthInteger>(
        _ value: JSONValue, _ type: I.Type, _ codingPath: [any CodingKey]
    ) throws -> I {
        switch value {
        case .int(let i):
            guard let v = I(exactly: i) else { throw numberDoesNotFit(type, "\(i)", codingPath) }
            return v
        case .number(let d):
            guard let v = I(exactly: d) else { throw numberDoesNotFit(type, "\(d)", codingPath) }
            return v
        default:
            throw typeMismatch(type, value, codingPath)
        }
    }

    private func unboxDate(_ value: JSONValue, _ codingPath: [any CodingKey]) throws -> Date {
        switch strategies.date {
        case .deferredToDate: return try Date(from: child(value, codingPath))
        case .secondsSince1970: return Date(timeIntervalSince1970: try unboxDouble(value, codingPath))
        case .millisecondsSince1970: return Date(timeIntervalSince1970: try unboxDouble(value, codingPath) / 1000)
        case .iso8601:
            let s = try unboxString(value, codingPath)
            guard let date = try? Date(s, strategy: .iso8601) else {
                throw dataCorrupted("Expected an ISO8601 date string", codingPath)
            }
            return date
        case .formatted(let formatter):
            let s = try unboxString(value, codingPath)
            guard let date = formatter.date(from: s) else {
                throw dataCorrupted("Date string does not match the expected format", codingPath)
            }
            return date
        case .custom(let body): return try body(child(value, codingPath))
        }
    }

    private func unboxData(_ value: JSONValue, _ codingPath: [any CodingKey]) throws -> Data {
        switch strategies.data {
        case .deferredToData: return try Data(from: child(value, codingPath))
        case .base64:
            let s = try unboxString(value, codingPath)
            guard let data = Data(base64Encoded: s) else { throw dataCorrupted("Invalid Base64 string", codingPath) }
            return data
        case .custom(let body): return try body(child(value, codingPath))
        }
    }

    func applyKeyDecoding(_ key: String) -> String {
        switch strategies.key {
        case .useDefaultKeys: return key
        case .convertFromSnakeCase: return convertFromSnakeCase(key)
        }
    }

    // MARK: - Errors

    func typeMismatch<T>(_ type: T.Type, _ value: JSONValue, _ codingPath: [any CodingKey]) -> DecodingError {
        DecodingError.typeMismatch(
            type, .init(codingPath: codingPath, debugDescription: "Expected \(type) but found \(value.kindLabel)"))
    }
    private func numberDoesNotFit<T>(_ type: T.Type, _ literal: String, _ codingPath: [any CodingKey]) -> DecodingError
    {
        DecodingError.dataCorrupted(
            .init(codingPath: codingPath, debugDescription: "Parsed JSON number \(literal) does not fit in \(type)"))
    }
    private func dataCorrupted(_ message: String, _ codingPath: [any CodingKey]) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: message))
    }
}

extension JSONValue {
    fileprivate var kindLabel: String {
        switch self {
        case .null: return "null"
        case .bool: return "a boolean"
        case .int, .number: return "a number"
        case .string: return "a string"
        case .array: return "an array"
        case .object: return "an object"
        }
    }
    fileprivate var isNull: Bool { if case .null = self { return true } else { return false } }
}

// MARK: - Keyed

private struct KeyedValueContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: JSONValueDecoderImpl
    let members: OrderedDictionary<String, JSONValue>
    var codingPath: [any CodingKey] { decoder.codingPath }

    init(decoder: JSONValueDecoderImpl, object: OrderedDictionary<String, JSONValue>) {
        self.decoder = decoder
        if case .useDefaultKeys = decoder.strategies.key {
            members = object
        } else {
            var converted = OrderedDictionary<String, JSONValue>()
            for (k, v) in object { converted[decoder.applyKeyDecoding(k)] = v }  // last value wins on collision
            members = converted
        }
    }

    var allKeys: [Key] { members.keys.compactMap { Key(stringValue: $0) } }
    func contains(_ key: Key) -> Bool { members[key.stringValue] != nil }

    private func value(_ key: Key) throws -> JSONValue {
        guard let v = members[key.stringValue] else {
            throw DecodingError.keyNotFound(
                key, .init(codingPath: codingPath, debugDescription: "No value for key \(key.stringValue)"))
        }
        return v
    }
    private func path(_ key: Key) -> [any CodingKey] { codingPath + [key] }

    func decodeNil(forKey key: Key) throws -> Bool { try value(key).isNull }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try decoder.unboxBool(value(key), path(key)) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try decoder.unboxString(value(key), path(key))
    }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try decoder.unboxDouble(value(key), path(key))
    }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try decoder.unboxFloat(value(key), path(key)) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try decoder.unboxInteger(value(key), type, path(key))
    }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try decoder.unboxInteger(value(key), type, path(key))
    }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try decoder.unboxInteger(value(key), type, path(key))
    }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try decoder.unboxInteger(value(key), type, path(key))
    }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try decoder.unboxInteger(value(key), type, path(key))
    }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try decoder.unboxInteger(value(key), type, path(key))
    }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try decoder.unboxInteger(value(key), type, path(key))
    }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try decoder.unboxInteger(value(key), type, path(key))
    }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try decoder.unboxInteger(value(key), type, path(key))
    }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try decoder.unboxInteger(value(key), type, path(key))
    }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try decoder.unbox(value(key), as: type, path(key))
    }

    func nestedContainer<NestedKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        try decoder.child(value(key), path(key)).container(keyedBy: type)
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try decoder.child(value(key), path(key)).unkeyedContainer()
    }
    func superDecoder() throws -> any Decoder { decoder.child(.object(members), codingPath) }
    func superDecoder(forKey key: Key) throws -> any Decoder { decoder.child(try value(key), path(key)) }
}

// MARK: - Unkeyed

private struct UnkeyedValueContainer: UnkeyedDecodingContainer {
    let decoder: JSONValueDecoderImpl
    let elements: [JSONValue]
    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { elements.count }
    var currentIndex = 0
    var isAtEnd: Bool { currentIndex >= elements.count }

    private mutating func next() throws -> (JSONValue, [any CodingKey]) {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                JSONValue.self,
                .init(codingPath: codingPath, debugDescription: "Unkeyed container is at end"))
        }
        let path = codingPath + [IndexKey(currentIndex)]
        let v = elements[currentIndex]
        currentIndex += 1
        return (v, path)
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { return false }
        if elements[currentIndex].isNull {
            currentIndex += 1
            return true
        }
        return false
    }
    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let (v, p) = try next()
        return try decoder.unboxBool(v, p)
    }
    mutating func decode(_ type: String.Type) throws -> String {
        let (v, p) = try next()
        return try decoder.unboxString(v, p)
    }
    mutating func decode(_ type: Double.Type) throws -> Double {
        let (v, p) = try next()
        return try decoder.unboxDouble(v, p)
    }
    mutating func decode(_ type: Float.Type) throws -> Float {
        let (v, p) = try next()
        return try decoder.unboxFloat(v, p)
    }
    mutating func decode(_ type: Int.Type) throws -> Int {
        let (v, p) = try next()
        return try decoder.unboxInteger(v, type, p)
    }
    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        let (v, p) = try next()
        return try decoder.unboxInteger(v, type, p)
    }
    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        let (v, p) = try next()
        return try decoder.unboxInteger(v, type, p)
    }
    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        let (v, p) = try next()
        return try decoder.unboxInteger(v, type, p)
    }
    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        let (v, p) = try next()
        return try decoder.unboxInteger(v, type, p)
    }
    mutating func decode(_ type: UInt.Type) throws -> UInt {
        let (v, p) = try next()
        return try decoder.unboxInteger(v, type, p)
    }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        let (v, p) = try next()
        return try decoder.unboxInteger(v, type, p)
    }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        let (v, p) = try next()
        return try decoder.unboxInteger(v, type, p)
    }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        let (v, p) = try next()
        return try decoder.unboxInteger(v, type, p)
    }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        let (v, p) = try next()
        return try decoder.unboxInteger(v, type, p)
    }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let (v, p) = try next()
        return try decoder.unbox(v, as: type, p)
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let (v, p) = try next()
        return try decoder.child(v, p).container(keyedBy: type)
    }
    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let (v, p) = try next()
        return try decoder.child(v, p).unkeyedContainer()
    }
    mutating func superDecoder() throws -> any Decoder {
        let (v, p) = try next()
        return decoder.child(v, p)
    }
}

// MARK: - Single value

private struct SingleValueValueContainer: SingleValueDecodingContainer {
    let decoder: JSONValueDecoderImpl
    let value: JSONValue
    var codingPath: [any CodingKey] { decoder.codingPath }

    func decodeNil() -> Bool { value.isNull }
    func decode(_ type: Bool.Type) throws -> Bool { try decoder.unboxBool(value, codingPath) }
    func decode(_ type: String.Type) throws -> String { try decoder.unboxString(value, codingPath) }
    func decode(_ type: Double.Type) throws -> Double { try decoder.unboxDouble(value, codingPath) }
    func decode(_ type: Float.Type) throws -> Float { try decoder.unboxFloat(value, codingPath) }
    func decode(_ type: Int.Type) throws -> Int { try decoder.unboxInteger(value, type, codingPath) }
    func decode(_ type: Int8.Type) throws -> Int8 { try decoder.unboxInteger(value, type, codingPath) }
    func decode(_ type: Int16.Type) throws -> Int16 { try decoder.unboxInteger(value, type, codingPath) }
    func decode(_ type: Int32.Type) throws -> Int32 { try decoder.unboxInteger(value, type, codingPath) }
    func decode(_ type: Int64.Type) throws -> Int64 { try decoder.unboxInteger(value, type, codingPath) }
    func decode(_ type: UInt.Type) throws -> UInt { try decoder.unboxInteger(value, type, codingPath) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try decoder.unboxInteger(value, type, codingPath) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try decoder.unboxInteger(value, type, codingPath) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try decoder.unboxInteger(value, type, codingPath) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try decoder.unboxInteger(value, type, codingPath) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try decoder.unbox(value, as: type, codingPath) }
}

private struct IndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { "Index \(intValue ?? 0)" }
    init(_ index: Int) { intValue = index }
    init?(intValue: Int) { self.intValue = intValue }
    init?(stringValue: String) { return nil }
}
