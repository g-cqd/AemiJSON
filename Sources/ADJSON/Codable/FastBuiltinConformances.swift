import Foundation

// Built-in `ADJSONFast{Decodable,Encodable}` conformances for the standard scalar types,
// `Array`, `Optional`, and string-keyed `Dictionary`. These make `[User]`, `User?`, and
// `[String: User]` themselves fast, so a top-level array or a nested field skips Codable's
// collection machinery (no per-element existential boxing). Part of the macro runtime SPI.

// Conditional conformances make `[FastType]` / `FastType?` themselves fast, so a
// top-level array or an optional field skips Codable's collection machinery.
extension Array: ADJSONFastDecodable where Element: ADJSONFastDecodable {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> [Element] {
        try c.fastArray(Element.self)
    }
}

extension Array: ADJSONFastEncodable where Element: ADJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout JSONByteWriter) throws {
        w.beginArray()
        var first = true
        for e in self {
            if first { first = false } else { w.comma() }
            try e.__adjsonEncode(into: &w)
        }
        w.endArray()
    }
}

extension String: ADJSONFastDecodable {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> String { try c.currentString() }
}
extension String: ADJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout JSONByteWriter) { w.string(self) }
}
extension Bool: ADJSONFastDecodable {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Bool { try c.currentBool() }
}
extension Bool: ADJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout JSONByteWriter) { w.bool(self) }
}
extension Double: ADJSONFastDecodable {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Double { try c.currentDouble() }
}
extension Double: ADJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout JSONByteWriter) throws { try w.double(self) }
}
extension Float: ADJSONFastDecodable {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Float {
        Float(try c.currentDouble())
    }
}
extension Float: ADJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout JSONByteWriter) throws { try w.double(Double(self)) }
}

extension ADJSONFastDecodable where Self: FixedWidthInteger {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
        try c.currentInteger(Self.self)
    }
}
extension ADJSONFastEncodable where Self: FixedWidthInteger {
    @inlinable public func __adjsonEncode(into w: inout JSONByteWriter) { w.integer(self) }
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
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Wrapped? {
        c.currentIsNull ? nil : try Wrapped.__adjsonDecode(c)
    }
}
extension Optional: ADJSONFastEncodable where Wrapped: ADJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout JSONByteWriter) throws {
        if let value = self { try value.__adjsonEncode(into: &w) } else { w.null() }
    }
}

extension Dictionary: ADJSONFastDecodable where Key == String, Value: ADJSONFastDecodable {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> [String: Value] {
        try c.fastDictionary(Value.self)
    }
}
extension Dictionary: ADJSONFastEncodable where Key == String, Value: ADJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout JSONByteWriter) throws {
        w.beginObject()
        var first = true
        for (key, value) in self {
            if first { first = false } else { w.comma() }
            w.dynamicKey(key)
            try value.__adjsonEncode(into: &w)
        }
        w.endObject()
    }
}
