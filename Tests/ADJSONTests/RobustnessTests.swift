import Foundation
import Testing

@testable import ADJSON

// Property-based robustness ("fuzz lite"): throw large volumes of random, mutated, and structured
// garbage at every untrusted-input entry point and assert nothing traps. The parser is iterative and
// bounds-guarded and the path parsers are depth-bounded, so every input must *return or throw* — the
// test completing without a crash is the assertion. Under the CI ASan/TSan passes this also exercises
// the unsafe scanner for OOB / use-after-free. (The coverage-guided libFuzzer target is separate.)
@Suite("Robustness")
struct RobustnessTests {
    // Exercise the whole read pipeline on one input under both validation modes.
    private func exercise(parse bytes: [UInt8]) {
        for options in [JSONParseOptions.strict, .lenient, .iJSON] {
            guard let document = try? ADJSON.parse(bytes, options: options) else { continue }
            let root = document.root
            let value = JSONValue(root)  // iterative full materialization
            _ = try? value.encodedBytes()
            _ = try? value.encodedBytes(options: .init(keyOrder: .sorted, prettyPrinted: true))
            _ = try? root.query("$..*")  // descendant wildcard over arbitrary structure
            _ = root[pointer: "/a/0/b"]
        }
    }

    @Test func parsingNeverTrapsOnRandomBytes() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<4000 {
            let count = Int.random(in: 0...80, using: &rng)
            exercise(parse: (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
        }
    }

    @Test func parsingNeverTrapsOnMutatedJSON() {
        var rng = SystemRandomNumberGenerator()
        let seeds = [
            #"{"a":1,"b":[1,2,3,true,null],"c":{"d":"eé"}}"#,
            "[[[[[[[]]]]]]]", #"{"k":"v","k":"v2"}"#, "-0.0e-99", #""😀""#,
            "1.7976931348623157e308", "[1,2,", #"{"a":"#, "\u{feff}{}",
        ]
        for seed in seeds {
            let base = Array(seed.utf8)
            guard !base.isEmpty else { continue }
            for _ in 0..<3000 {
                var bytes = base
                switch Int.random(in: 0...3, using: &rng) {
                case 0: bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                case 1:
                    bytes.insert(
                        UInt8.random(in: 0...255, using: &rng), at: Int.random(in: 0...bytes.count, using: &rng))
                case 2: bytes.remove(at: Int.random(in: 0..<bytes.count, using: &rng))
                default: bytes += base  // duplicate to deepen / lengthen
                }
                exercise(parse: bytes)
            }
        }
    }

    @Test func pathParsersNeverTrapOnRandomStrings() {
        var rng = SystemRandomNumberGenerator()
        // Bias the alphabet toward path metacharacters so the grammar is actually stressed.
        let alphabet = Array(#"$.[]()?@*:,'"!=<>&|-_0123 \uabZ#"#.utf8)
        for _ in 0..<8000 {
            let count = Int.random(in: 0...40, using: &rng)
            let bytes = (0..<count).map { _ in alphabet.randomElement(using: &rng)! }
            let string = String(decoding: bytes, as: UTF8.self)
            _ = try? JSONPath(string)
            _ = try? SQLiteJSONPath(string)
        }
    }
}
