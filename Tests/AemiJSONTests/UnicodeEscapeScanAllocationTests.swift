import AemiJSON
import AemiTestKit
import Testing

/// Scanning validates every `\uXXXX` escape (four hex digits, surrogate pairing) without decoding it, so an escape must cost
/// no allocation: a document of `\u` strings allocates exactly what the same document of plain strings does. In a debug
/// build the four-digit loop of `hex4` allocated once per digit, four times per escape (2026-10-29: 402 allocations for 100
/// escaped strings against 2 for 100 plain ones), which made `escapedKeysDoNotAllocatePerKey` fail in debug only.
/// (Where allocation counting is unavailable this records nothing.)
struct UnicodeEscapeScanAllocationTests {
    private static func array(of element: String) -> [UInt8] {
        Array(("[" + Array(repeating: element, count: 100).joined(separator: ",") + "]").utf8)
    }

    @Test(arguments: [#""\u006b""#, #""\u00e9\u00e9""#, #""\ud83d\ude00""#])
    func `a unicode escape is validated without allocating`(element: String) {
        let options = JSONParseOptions(validation: .strict)
        let plain = Self.array(of: #""kk""#)
        let escaped = Self.array(of: element)
        _ = try? AemiJSON.parse(plain, options: options)  // warm up lazy one-time work
        _ = try? AemiJSON.parse(escaped, options: options)
        let plainCount = minimumAllocations { _ = try? AemiJSON.parse(plain, options: options) }
        let escapedCount = minimumAllocations { _ = try? AemiJSON.parse(escaped, options: options) }
        guard let plainCount, let escapedCount else { return }
        #expect(escapedCount == plainCount, "plain \(plainCount) allocations, escaped \(escapedCount)")
    }
}
