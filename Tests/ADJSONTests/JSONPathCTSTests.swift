import Foundation
import Testing

@testable import ADJSON

// The CTS corpus is vendored on demand (run `scripts/fetch-fixtures.sh`); locate it once so the
// test can be *skipped* — not silently passed — when it is absent.
private func jsonPathCTSURL() -> URL? {
    Bundle.module.url(forResource: "cts", withExtension: "json", subdirectory: "Resources/JSONPathCTS")
}

// RFC 9535 JSONPath Compliance Test Suite. The engine rejects every invalid selector and returns
// the expected nodelist for all valid queries except a handful of I-Regexp (RFC 9485) edge cases
// (`.` vs the U+2028/U+2029 line separators under Swift's regex engine), so this asserts full
// invalid-rejection and a high valid-query floor.
@Test(.enabled(if: jsonPathCTSURL() != nil, "JSONPath CTS fixtures absent; run scripts/fetch-fixtures.sh"))
func jsonPathComplianceSuite() throws {
    let url = try #require(jsonPathCTSURL())
    let root = try ADJSON.parse(Data(contentsOf: url)).root
    let tests = root["tests"].arrayValue

    var validTotal = 0
    var validOK = 0
    var invalidTotal = 0
    var invalidRejected = 0

    for test in tests {
        guard let selector = test["selector"].string else { continue }
        if test["invalid_selector"].boolValue {
            invalidTotal += 1
            if (try? JSONPath(selector)) == nil { invalidRejected += 1 }
            continue
        }
        validTotal += 1
        guard let path = try? JSONPath(selector) else { continue }
        let document = test["document"]
        let result = path.query(document)
        let expectedLists: [[JSON]] =
            test["results"].exists
            ? test["results"].arrayValue.map(\.arrayValue)
            : [test["result"].arrayValue]
        let matched = expectedLists.contains { expected in
            expected.count == result.count && zip(expected, result).allSatisfy { jsonSemanticEqual($0, $1) }
        }
        if matched { validOK += 1 }
    }

    let rate = validTotal == 0 ? 0 : Double(validOK) / Double(validTotal)
    print(
        "JSONPath CTS: valid \(validOK)/\(validTotal) (\(Int(rate * 100))%), "
            + "invalid rejected \(invalidRejected)/\(invalidTotal)")
    #expect(validTotal > 100)
    #expect(invalidRejected == invalidTotal, "every invalid selector must be rejected")
    #expect(rate >= 0.98, "JSONPath CTS valid-query pass rate regressed")
}
