import Foundation
import Testing

@testable import ADJSON

// Runs Nicolas Seriot's JSONTestSuite ("Parsing JSON is a Minefield"):
//   y_*  MUST parse,  n_*  MUST be rejected,  i_*  implementation-defined (recorded).

struct SuiteCase: Sendable, CustomTestStringConvertible {
    let name: String
    let data: Data
    var testDescription: String { name }
}

private func loadSuite() -> [SuiteCase] {
    guard let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Resources/JSONTestSuite")
    else { return [] }
    return urls.compactMap { url in
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SuiteCase(name: url.lastPathComponent, data: data)
    }
    .sorted { $0.name < $1.name }
}

@Test func jsonTestSuiteLoaded() {
    let count = loadSuite().count
    // Fixtures are vendored on demand; run `scripts/fetch-fixtures.sh` to enable.
    guard count > 0 else { return }
    #expect(count > 250)
}

@Test(arguments: loadSuite())
func jsonTestSuiteParsing(_ testCase: SuiteCase) {
    let parsed = (try? ADJSON.parse(testCase.data)) != nil
    if testCase.name.hasPrefix("y_") {
        #expect(parsed, "y_ case must parse")
    } else if testCase.name.hasPrefix("n_") {
        #expect(!parsed, "n_ case must be rejected")
    }
    // i_ cases are implementation-defined; we don't assert either way.
}
