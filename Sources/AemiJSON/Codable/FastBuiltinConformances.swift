#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

// Built-in `AemiJSONFast{Decodable,Encodable}` conformances for the standard scalar types,
// `Array`, `Optional`, and string-keyed `Dictionary`. These make `[User]`, `User?`, and
// `[String: User]` themselves fast, so a top-level array or a nested field skips Codable's
// collection machinery (no per-element existential boxing). Part of the macro runtime SPI.

// Conditional conformances make `[FastType]` / `FastType?` themselves fast, so a
// top-level array or an optional field skips Codable's collection machinery.
extension Array: AemiJSONFastDecodable where Element: AemiJSONFastDecodable {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> [Element] {
        try c.fastArray(Element.self)
    }
}

extension Array: AemiJSONFastEncodable where Element: AemiJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout _JSONByteWriter) throws {
        w.beginArray()
        var first = true
        for e in self {
            if first { first = false } else { w.comma() }
            try e.__adjsonEncode(into: &w)
        }
        w.endArray()
    }
}

extension String: AemiJSONFastDecodable {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> String { try c.currentString() }
}
extension String: AemiJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout _JSONByteWriter) { w.string(self) }
}
extension Bool: AemiJSONFastDecodable {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Bool { try c.currentBool() }
}
extension Bool: AemiJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout _JSONByteWriter) { w.bool(self) }
}
extension Double: AemiJSONFastDecodable {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Double { try c.currentDouble() }
}
extension Double: AemiJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout _JSONByteWriter) throws { try w.double(self) }
}
extension Float: AemiJSONFastDecodable {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Float {
        try c.currentFloat()
    }
}
extension Float: AemiJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout _JSONByteWriter) throws { try w.float(self) }
}

extension AemiJSONFastDecodable where Self: FixedWidthInteger {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
        try c.currentInteger(Self.self)
    }
}
extension AemiJSONFastEncodable where Self: FixedWidthInteger {
    @inlinable public func __adjsonEncode(into w: inout _JSONByteWriter) { w.integer(self) }
}
extension Int: AemiJSONFastDecodable {}
extension Int: AemiJSONFastEncodable {}
extension Int8: AemiJSONFastDecodable {}
extension Int8: AemiJSONFastEncodable {}
extension Int16: AemiJSONFastDecodable {}
extension Int16: AemiJSONFastEncodable {}
extension Int32: AemiJSONFastDecodable {}
extension Int32: AemiJSONFastEncodable {}
extension Int64: AemiJSONFastDecodable {}
extension Int64: AemiJSONFastEncodable {}
extension UInt: AemiJSONFastDecodable {}
extension UInt: AemiJSONFastEncodable {}
extension UInt8: AemiJSONFastDecodable {}
extension UInt8: AemiJSONFastEncodable {}
extension UInt16: AemiJSONFastDecodable {}
extension UInt16: AemiJSONFastEncodable {}
extension UInt32: AemiJSONFastDecodable {}
extension UInt32: AemiJSONFastEncodable {}
extension UInt64: AemiJSONFastDecodable {}
extension UInt64: AemiJSONFastEncodable {}

extension Optional: AemiJSONFastDecodable where Wrapped: AemiJSONFastDecodable {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Wrapped? {
        c.currentIsNull ? nil : try Wrapped.__adjsonDecode(c)
    }
}
extension Optional: AemiJSONFastEncodable where Wrapped: AemiJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout _JSONByteWriter) throws {
        if let value = self { try value.__adjsonEncode(into: &w) } else { w.null() }
    }
}

extension Dictionary: AemiJSONFastDecodable where Key == String, Value: AemiJSONFastDecodable {
    @inlinable public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> [String: Value] {
        try c.fastDictionary(Value.self)
    }
}
extension Dictionary: AemiJSONFastEncodable where Key == String, Value: AemiJSONFastEncodable {
    @inlinable public func __adjsonEncode(into w: inout _JSONByteWriter) throws {
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
