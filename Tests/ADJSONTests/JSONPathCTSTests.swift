import Foundation
import Testing

@testable import ADJSON

// RFC 9535 JSONPath Compliance Test Suite. Our engine implements a documented
// subset (no `value()`, no formal well-typedness checker, object-member order is
// unspecified), so this reports a pass rate and asserts a floor rather than 100%.
@Test func jsonPathComplianceSuite() throws {
    guard
        let url = Bundle.module.url(
            forResource: "cts", withExtension: "json", subdirectory: "Resources/JSONPathCTS")
    else {
        // Fixtures are vendored on demand; run `scripts/fetch-fixtures.sh` to enable.
        return
    }
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
    #expect(invalidRejected > 0)
    #expect(rate >= 0.5, "JSONPath CTS pass rate regressed below the documented subset floor")
}
