// Word-at-a-time byte equality for JSON object-key matching — the single source of truth for the
// three key-compare sites (lazy navigation, generic decode, and the `@JSONCodable` fast path).
// Namespaced under `JSONKey` to match the other byte helpers (`JSONString`/`JSONNumber`/`JSONUTF8`/
// `JSONOutput`). Pure stdlib (no C `memcmp`), so it stays `@inlinable` under
// `InternalImportsByDefault` while the optimizer lowers it to a bulk compare.
@usableFromInline
enum JSONKey {
    // Compares 8 bytes per step and then the `< 8`-byte remainder, so it never reads past `count`;
    // equality is endianness-agnostic (both sides load identically), so no byte-swapping is needed.
    @inlinable
    static func bytesEqual(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ count: Int) -> Bool {
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
    static func bytesEqual(_ key: String, _ b: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        var k = key
        return k.withUTF8 { kb in
            guard kb.count == count else { return false }
            guard let ka = kb.baseAddress else { return count == 0 }
            return bytesEqual(ka, b, count)
        }
    }
}
