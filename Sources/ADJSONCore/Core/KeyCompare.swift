// Word-at-a-time byte equality for JSON object-key matching — the single source of truth for the
// three key-compare sites (lazy navigation, generic decode, and the `@JSONCodable` fast path).
// Namespaced under `JSONKey` to match the other byte helpers (`JSONString`/`JSONNumber`/`JSONUTF8`/
// `JSONOutput`). Pure stdlib (no C `memcmp`), so it stays `@inlinable` under
// `InternalImportsByDefault` while the optimizer lowers it to a bulk compare.
public enum JSONKey {
    // Compares 8 bytes per step and then the `< 8`-byte remainder, so it never reads past `count`;
    // equality is endianness-agnostic (both sides load identically), so no byte-swapping is needed.
    @inlinable
    public static func bytesEqual(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        var i = 0
        while i &+ 8 <= count {
            let wa = UnsafeRawPointer(a + i).loadUnaligned(as: UInt64.self)
            let wb = UnsafeRawPointer(b + i).loadUnaligned(as: UInt64.self)
            if wa != wb { return false }
            i &+= 8
        }
        while i < count {
            if a[i] != b[i] { return false }
            i &+= 1
        }
        return true
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
        if escaped { return JSONString.unescape(p, off, len) == key }
        return bytesEqual(key, p + off, len)
    }

    @inlinable
    public static func matches(
        _ p: UnsafePointer<UInt8>, _ off: Int, _ len: Int, escaped: Bool, _ key: StaticString
    ) -> Bool {
        if escaped { return JSONString.unescape(p, off, len) == key.description }
        return len == key.utf8CodeUnitCount && bytesEqual(p + off, key.utf8Start, len)
    }
}
