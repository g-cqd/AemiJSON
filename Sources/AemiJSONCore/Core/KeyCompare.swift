// `public import`: the `@inlinable` members below reference `AemiKernel.ByteCompare`, so AemiKernel must
// be part of this module's public/inlinable surface (an internal import would make the referenced
// symbol invisible to inlinable bodies).
public import AemiKernel

// Byte equality + escape-aware key matching for JSON object keys — the single source of truth for
// the three key-compare sites (lazy navigation, generic decode, and the `@JSONCodable` fast path).
// The word-at-a-time byte compare lives in ``AemiKernel/ByteCompare``; this layer adds the JSON
// escape-aware variants. Pure stdlib, so it stays `@inlinable` under `InternalImportsByDefault`.
public enum JSONKey {
    @inlinable
    public static func bytesEqual(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        unsafe ByteCompare.equal(a, b, count)
    }

    // Compares a Swift `String` key's UTF-8 against a raw key buffer (the sites where one side is a
    // `String` rather than a tape/`StaticString` byte range).
    @inlinable
    public static func bytesEqual(_ key: String, _ b: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        var k = key
        return k.withUTF8 { kb in
            guard kb.count == count else { return false }
            guard let ka = kb.baseAddress else { return count == 0 }
            return unsafe bytesEqual(ka, b, count)
        }
    }

    /// Matches a parsed object key with a string, decoding escapes according to the parse mode.
    /// - Parameters:
    ///   - p: Backing UTF-8 buffer.
    ///   - off: Start of the key body in `p`.
    ///   - len: Byte length of the key body.
    ///   - escaped: Whether the key body contains an escape.
    ///   - json5: Whether the parser accepted JSON5 escapes in this key.
    ///   - key: Decoded key to compare.
    /// - Returns: Whether the parsed key equals `key`.
    /// - Precondition: The parser validated `p[off ..< off + len]`, which remains valid for this call.
    /// - Complexity: O(len + the string's UTF-8 length) time and O(1) extra space.
    @inlinable
    public static func matches(
        _ p: UnsafePointer<UInt8>, _ off: Int, _ len: Int, escaped: Bool, json5: Bool = false, _ key: String
    ) -> Bool {
        // Caller owns `p[off ..< off + len]` for this call; `p` is read-only and never escapes.
        assert(off >= 0 && len >= 0, "key match requires a non-negative byte range")
        if escaped {
            var k = key
            return k.withUTF8 { kb in
                guard let kp = kb.baseAddress else { return len == 0 }
                if json5 {
                    return unsafe JSONString.unescapedEqualsJSON5(p, off, len, kp, kb.count)
                }
                return unsafe JSONString.unescapedEquals(p, off, len, kp, kb.count)
            }
        }
        return unsafe bytesEqual(key, p + off, len)
    }

    /// Matches a parsed object key with a static string without materializing the key.
    /// - Parameters:
    ///   - p: Backing UTF-8 buffer.
    ///   - off: Start of the key body in `p`.
    ///   - len: Byte length of the key body.
    ///   - escaped: Whether the key body contains an escape.
    ///   - json5: Whether the parser accepted JSON5 escapes in this key.
    ///   - key: Static key to compare.
    /// - Returns: Whether the parsed key equals `key`.
    /// - Precondition: The parser validated `p[off ..< off + len]`, which remains valid for this call.
    /// - Complexity: O(len) time and O(1) extra space.
    @inlinable
    public static func matches(
        _ p: UnsafePointer<UInt8>, _ off: Int, _ len: Int, escaped: Bool, json5: Bool = false, _ key: StaticString
    ) -> Bool {
        if escaped {
            if json5 {
                return unsafe JSONString.unescapedEqualsJSON5(p, off, len, key.utf8Start, key.utf8CodeUnitCount)
            }
            return unsafe JSONString.unescapedEquals(p, off, len, key.utf8Start, key.utf8CodeUnitCount)
        }
        return unsafe len == key.utf8CodeUnitCount && bytesEqual(p + off, key.utf8Start, len)
    }
}
