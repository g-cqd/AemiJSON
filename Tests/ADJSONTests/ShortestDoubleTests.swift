import AemiTestKit
import Testing

@testable import ADJSONCore

// The shortest-Double formatter (`JSONShortest`) is correct **by construction** (the digit count is the
// smallest precision whose rounding round-trips). These tests are the gate: every finite double must
// round-trip exactly, the canonical presentation is pinned, and the significant digits match Swift's
// own shortest (`Double.description`) — only the fixed/scientific placement may differ.

private func shortest(_ d: Double) -> String {
    var bytes: [UInt8] = []
    JSONShortest.appendShortest(d, to: &bytes)
    return String(decoding: bytes, as: UTF8.self)
}

/// Significant digits of a decimal string, ignoring sign, point, exponent, and leading/trailing zeros.
private func significantDigits(_ s: String) -> String {
    var out = ""
    var mantissa = s
    if let eIndex = mantissa.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = String(mantissa[mantissa.startIndex ..< eIndex])
    }
    for ch in mantissa where ch.isNumber { out.append(ch) }
    // Strip leading and trailing zeros (they carry no significance).
    while out.count > 1, out.first == "0" { out.removeFirst() }
    while out.count > 1, out.last == "0" { out.removeLast() }
    return out
}

struct ShortestDoubleTests {
    @Test func canonicalForms() {
        // AemiTestKit's typed asserts: nineteen `#expect` macro expansions tipped this body past the
        // 100ms type-check budget; the plain generic calls keep every check independent and cheap.
        expectEqual(shortest(0), "0.0")
        expectEqual(shortest(-0.0), "-0.0")
        expectEqual(shortest(2), "2.0")
        expectEqual(shortest(-2), "-2.0")
        expectEqual(shortest(0.1), "0.1")
        expectEqual(shortest(0.5), "0.5")
        expectEqual(shortest(3.5), "3.5")
        expectEqual(shortest(-0.25), "-0.25")
        expectEqual(shortest(100), "100.0")
        expectEqual(shortest(1234.5678), "1234.5678")
        expectEqual(shortest(0.0001), "0.0001")
        expectEqual(shortest(1e-5), "1e-05")
        expectEqual(shortest(1e15), "1000000000000000.0")
        expectEqual(shortest(1e16), "1e+16")
        expectEqual(shortest(1e20), "1e+20")
        expectEqual(shortest(1.5e300), "1.5e+300")
        // The 5e-324 denormal via its named constant — the x86_64 Linux frontend rejects the
        // literal ("underflows and loses precision") under warnings-as-errors; arm64 accepts it.
        expectEqual(shortest(Double.leastNonzeroMagnitude), "5e-324")
        // The 2^53 region: deterministic fixed form (Swift's `description` flips some of these to
        // scientific — the intended, round-trip-safe divergence).
        expectEqual(shortest(9_007_199_254_740_992), "9007199254740992.0")
        expectEqual(shortest(9_999_999_999_999_998), "9999999999999998.0")
    }

    @Test func roundTripsEdgeCases() {
        let edges: [Double] = [
            0, -0.0, 1, -1, 0.1, 0.2, 0.3, 0.5, 1.5, 3.14, 100, 123_456_789,
            .leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
            1e15, 1e16, 1e-4, 1e-5, 9_007_199_254_740_992, 9_007_199_254_740_994, 9_999_999_999_999_998,
            // `5e-324` (the smallest subnormal) is already covered above as `.leastNonzeroMagnitude`
            // — the bare decimal literal is omitted here because the x86_64 Linux frontend rejects it
            // as "underflows and loses precision" under warnings-as-errors (Darwin accepts it).
            1.797_693_134_862_315_7e308, 2.225_073_858_507_201_4e-308, 0.300_000_000_000_000_04,
            1e20, 1e21, 1.5e300, 1.5e-300, -73.962_660_001
        ]
        for d in edges {
            #expect(Double(shortest(d))?.bitPattern == d.bitPattern, "\(d) -> \(shortest(d))")
        }
    }

    // Every finite double's rendered form must parse back (via the stdlib's correctly-rounded
    // `Double(_:)`) to the exact same bit pattern, and use the shortest digits Swift would.
    @Test func roundTripsAndMatchesSwiftDigitsOnRandomDoubles() {
        var rng = SystemRandomNumberGenerator()
        var checked = 0
        for _ in 0 ..< 300_000 {
            let d = Double(bitPattern: UInt64.random(in: UInt64.min ... UInt64.max, using: &rng))
            guard d.isFinite else { continue }
            checked += 1
            let s = shortest(d)
            guard Double(s)?.bitPattern == d.bitPattern else {
                Issue.record("round-trip failed: bits=\(d.bitPattern) -> \(s)")
                break
            }
            guard significantDigits(s) == significantDigits(d.description) else {
                Issue.record("digit mismatch: \(d.description) -> \(s)")
                break
            }
        }
        #expect(checked > 0)
    }

    // Structured sweep across every binary exponent with a handful of mantissa patterns, to catch any
    // exponent-boundary error the uniform random sample might under-weight.
    @Test func roundTripsAcrossExponentSweep() {
        for exp in 0 ..< 2048 {
            for mantissa: UInt64 in [0, 1, 2, 0x8_0000_0000_0000, 0xF_FFFF_FFFF_FFFF] {
                let bits = (UInt64(exp) << 52) | mantissa
                let d = Double(bitPattern: bits)
                guard d.isFinite else { continue }
                #expect(Double(shortest(d))?.bitPattern == d.bitPattern, "bits=\(bits) -> \(shortest(d))")
            }
        }
    }
}
