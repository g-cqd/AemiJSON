// `public import`: the `@inlinable` members below reference `ADFCore.ByteCompare`, so ADFCore must
// be part of this module's public/inlinable surface (an internal import would make the referenced
// symbol invisible to inlinable bodies).
public import ADFCore

// Byte equality + escape-aware key matching for JSON object keys — the single source of truth for
// the three key-compare sites (lazy navigation, generic decode, and the `@JSONCodable` fast path).
// The word-at-a-time byte compare lives in ``ADFCore/ByteCompare``; this layer adds the JSON
// escape-aware variants. Pure stdlib, so it stays `@inlinable` under `InternalImportsByDefault`.
public enum JSONKey {
    @inlinable
    public static func bytesEqual(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        ByteCompare.equal(a, b, count)
    }

    // Compares a Swift `String` key's UTF-8 against a raw key buffer (the sites where one side is a
    // `String` rather than a tape/`StaticString` byte range).
    @inlinable
    public static func bytesEqual(_ key: String, _ b: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        var k = key
        return k.withUTF8 { kb in
            guard kb.count == count else { return false }
            guard let ka = kb.baseAddress else { return count == 0 }
            return bytesEqual(ka, b, count)
        }
    }

    // Escape-aware key match against a raw key slot's bytes (`p[off..<off+len]`, `escaped` = the
    // tape's hasEscape flag). This owns the escape branch that the lazy-navigation, generic-decode,
    // and `@JSONCodable` fast-path lookups all share, so the policy lives in exactly one place.
    @inlinable
    public static func matches(
        _ p: UnsafePointer<UInt8>, _ off: Int, _ len: Int, escaped: Bool, _ key: String
    ) -> Bool {
        // Caller owns `p[off ..< off + len]` for this call; `p` is read-only and never escapes.
        assert(off >= 0 && len >= 0, "key match requires a non-negative byte range")
        if escaped {
            var k = key
            return k.withUTF8 { kb in
                guard let kp = kb.baseAddress else { return len == 0 }
                return JSONString.unescapedEquals(p, off, len, kp, kb.count)
            }
        }
        return bytesEqual(key, p + off, len)
    }

    @inlinable
    public static func matches(
        _ p: UnsafePointer<UInt8>, _ off: Int, _ len: Int, escaped: Bool, _ key: StaticString
    ) -> Bool {
        if escaped { return JSONString.unescapedEquals(p, off, len, key.utf8Start, key.utf8CodeUnitCount) }
        return len == key.utf8CodeUnitCount && bytesEqual(p + off, key.utf8Start, len)
    }
}
