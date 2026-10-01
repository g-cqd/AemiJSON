import Testing

@testable import AemiJSONCore

// The number fast paths hold a decimal significand in an integer, which limits them to 19 significant
// digits for `Double` and 7 for `Float`. Zeros that only pad the number — before the first significant
// digit, or after the last — cost nothing there, so they must not use up that budget: before, they did,
// and `0.000000000000000000001` fell back to building a `String` for the standard library to parse.

private func fastDouble(_ text: String) -> Double? {
    Array(text.utf8)
        .withUnsafeBufferPointer { buffer in
            buffer.baseAddress.flatMap { JSONNumber.parseDoubleFast($0, 0, buffer.count) }
        }
}

private func fastFloat(_ text: String) -> Float? {
    Array(text.utf8)
        .withUnsafeBufferPointer { buffer in
            buffer.baseAddress.flatMap { JSONNumber.parseFloatFast($0, 0, buffer.count) }
        }
}

private func parsedDouble(_ text: String) -> Double {
    Array(text.utf8)
        .withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { JSONNumber.parseDouble($0, 0, buffer.count) } ?? .nan
        }
}

private func parsedFloat(_ text: String) -> Float {
    Array(text.utf8)
        .withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { JSONNumber.parseFloat($0, 0, buffer.count) } ?? .nan
        }
}

struct NumberFastPathTests {
    @Test(arguments: [
        "0.000000000000000000001", "1.0000000000000000000000", "-0.00000000000000000000000012345",
        "123000000000000000000000", "0.10000000000000000000000000", "00.5", "-0.000000000000000000000",
        "1234567890123456789.000000", "0.000000000000000000000000000001e10"
    ])
    func zeroPaddingKeepsTheDoubleFastPath(_ text: String) throws {
        let fast = try #require(fastDouble(text), "\(text) left the fast path")
        #expect(fast.bitPattern == Double(text)?.bitPattern)
    }

    @Test(arguments: ["0.0000000001", "1.00000000000", "0.0000012345e5", "12300000000", "-0.000"])
    func zeroPaddingKeepsTheFloatFastPath(_ text: String) throws {
        let fast = try #require(fastFloat(text), "\(text) left the fast path")
        #expect(fast.bitPattern == Float(text)?.bitPattern)
    }

    // Zeros between significant digits still count, and an exponent too long to hold exactly still
    // leaves the fast path: a long run of zeros must not bring a clamped exponent back into range.
    @Test func interiorZerosAndLongExponentsStillLeaveTheFastPath() {
        #expect(fastDouble("10000000000000000000001") == nil)
        #expect(fastFloat("100000001") == nil)
        let zeros = String(repeating: "0", count: 999_999)
        let hugeTimesTiny = "0." + zeros + "1e10000000"  // 1e-1000000 × 1e10000000
        #expect(fastDouble(hugeTimesTiny) == nil)
        #expect(parsedDouble(hugeTimesTiny) == .infinity)
    }

    // A decimal far too long for `Double(_:)` on every platform (Linux rejects tens of thousands of digits)
    // still rounds exactly: digits past the 768th only matter as a nonzero tail, and a huge or tiny
    // exponent reads as overflow or underflow, never as NaN.
    @Test func veryLongDecimalsRoundLikeTheirExactValue() {
        let padding = String(repeating: "0", count: 100_000)
        #expect(parsedDouble("0.1" + padding) == 0.1)
        #expect(parsedDouble("1." + padding + "1") == 1.0)
        #expect(parsedDouble("-1" + padding + "e-100000") == -1.0)
        #expect(parsedDouble("0." + padding + "1e100000") == 0.1)
        #expect(parsedDouble("0." + padding + "1e-400") == 0.0)
        #expect(parsedDouble("1" + padding + "e1000000000000") == .infinity)
        #expect(parsedDouble("-1" + padding + "e1000000000000") == -.infinity)
        #expect(parsedDouble("0." + padding + "1e-1000000000000") == 0.0)
        #expect(parsedDouble("-0." + padding) == 0.0 && parsedDouble("-0." + padding).sign == .minus)
        #expect(parsedFloat("0.5" + padding) == 0.5)
        #expect(parsedFloat("1" + padding + "e1000000000000") == .infinity)
    }

    // 2^53 + 1 sits exactly between two doubles: padding with zeros keeps round-half-to-even, while a
    // nonzero digit hundreds of places later, well past any budget, must push it up.
    @Test func halfwayDecimalsKeepTheirTailThroughTheCutoff() {
        let padding = String(repeating: "0", count: 100_000)
        #expect(parsedDouble("9007199254740993." + padding) == 9007199254740992.0)
        #expect(parsedDouble("9007199254740993." + padding + "1") == 9007199254740994.0)
        #expect(parsedFloat("16777217." + padding) == 16777216.0)
        #expect(parsedFloat("16777217." + padding + "1") == 16777218.0)
    }

    // Random decimals with padding and interior zeros, through the whole parse (fast path or not),
    // must match the standard library bit for bit.
    @Test func paddedDecimalsParseLikeTheStandardLibrary() {
        var state: UInt64 = 0x243F_6A88_85A3_08D3
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33) % bound
        }
        func digits(_ count: Int) -> String {  // two thirds zeros
            String((0 ..< count).map { _ in Character(String(next(3) > 0 ? 0 : next(10))) })
        }
        for _ in 0 ..< 20_000 {
            var text = next(2) == 0 ? "-" : ""
            text += next(3) == 0 ? "0" : String(1 + next(9)) + digits(next(12))
            if next(2) == 0 { text += "." + digits(1 + next(30)) }
            if next(3) == 0 { text += "e" + (next(2) == 0 ? "-" : "") + String(next(40)) }
            guard let double = Double(text), let float = Float(text) else {
                Issue.record("the standard library rejected \(text)")
                continue
            }
            #expect(parsedDouble(text).bitPattern == double.bitPattern, "\(text)")
            #expect(parsedFloat(text).bitPattern == float.bitPattern, "\(text)")
        }
    }
}
