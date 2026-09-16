import AemiJSON
import Foundation
import Testing

// AemiJSON's snake_case key conversion is a hand-maintained port of swift-foundation's (private)
// JSONEncoder/JSONDecoder algorithm. Foundation does not expose the function, so guard against drift by
// comparing AemiJSON's live output to Foundation's own across a representative set of key shapes:
// acronyms, digits, runs of capitals, existing underscores, and leading/trailing underscores.
struct SnakeCaseParityTests {
    private struct Keys: Codable, Equatable {
        var id = 1
        var userName = "a"
        var aURL = "b"
        var htmlAPIResponse = "c"
        var version2Point0 = "d"
        var iOSDevice = "e"
        var already = "f"
        var has_underscores = "g"
        var trailingUnderscore_ = "h"
    }

    private func sortedKeys(_ data: Data) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object ?? [:]).keys.sorted()
    }

    @Test func encodingKeysMatchFoundation() throws {
        var aemijson = AemiJSON.JSONEncoder()
        aemijson.keyEncodingStrategy = .convertToSnakeCase
        let foundation = Foundation.JSONEncoder()
        foundation.keyEncodingStrategy = .convertToSnakeCase

        let aemijsonKeys = try sortedKeys(aemijson.encode(Keys()))
        let foundationKeys = try sortedKeys(foundation.encode(Keys()))
        #expect(aemijsonKeys == foundationKeys)
        #expect(aemijsonKeys.count == 9)  // all nine properties present (nothing dropped/collided)
    }

    // snake_case → camelCase is bijective only without acronyms (`aURL` → `a_url` → `aUrl`), so the
    // decode-parity check uses round-trip-safe keys; the lossy acronym direction is already covered by
    // the encoding test above (which compares AemiJSON's snake output to Foundation's directly).
    private struct RoundTripKeys: Codable, Equatable {
        var id = 7
        var userName = "a"
        var firstSeenAt = "b"
        var totalItemCount = 3
        var isEnabled = true
    }

    @Test func decodingFromSnakeCaseMatchesFoundation() throws {
        let foundationEncoder = Foundation.JSONEncoder()
        foundationEncoder.keyEncodingStrategy = .convertToSnakeCase
        let snake = try foundationEncoder.encode(RoundTripKeys())

        var aemijsonDecoder = AemiJSON.JSONDecoder()
        aemijsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let foundationDecoder = Foundation.JSONDecoder()
        foundationDecoder.keyDecodingStrategy = .convertFromSnakeCase

        let viaAemiJSON = try aemijsonDecoder.decode(RoundTripKeys.self, from: snake)
        let viaFoundation = try foundationDecoder.decode(RoundTripKeys.self, from: snake)
        #expect(viaAemiJSON == viaFoundation)
        #expect(viaAemiJSON == RoundTripKeys())  // clean round-trip back to the original
    }
}
