import Foundation
import Testing

@testable import ADJSON

/// Correctness gate for the fast ISO 8601 date parser. The contract is that `DateDataDecoding.iso8601`
/// is byte-identical to Foundation's `Date(_, strategy: .iso8601)` for *every* input — the fast path
/// only accelerates the canonical `YYYY-MM-DDTHH:MM:SSZ` UTC form and defers everything else to
/// Foundation — so the oracle is: `iso8601(s)` and `Date(s, strategy: .iso8601)` agree (both nil, or the
/// same instant) for all `s`. Any divergence is a bug.
struct ISO8601FastTests {
    private func agrees(_ s: String) -> Bool {
        let ours = DateDataDecoding.iso8601(s)
        let foundation = try? Date(s, strategy: .iso8601)
        switch (ours, foundation) {
            case (nil, nil):
                return true
            case (let o?, let f?):
                return o.timeIntervalSinceReferenceDate == f.timeIntervalSinceReferenceDate
            default:
                return false
        }
    }

    @Test func fastPathHandlesBothCalendarEras() {
        // The fast path itself (not the Foundation fallback) must resolve valid dates in both the Julian
        // (pre-1583) and Gregorian (1583+) eras — returning non-nil — and only defer the reform year 1582.
        func fast(_ s: String) -> Date? {
            var s = s
            return s.withUTF8 { DateDataDecoding.fastISO8601($0) }
        }
        #expect(fast("1000-06-15T12:34:56Z") != nil)  // Julian branch engaged
        #expect(fast("0100-01-01T00:00:00Z") != nil)
        #expect(fast("1581-12-31T23:59:59Z") != nil)  // last Julian year handled here
        #expect(fast("1580-02-29T00:00:00Z") != nil)  // Julian leap day (÷4, no century rule)
        #expect(fast("2020-01-01T00:00:00Z") != nil)  // Gregorian branch engaged
        #expect(fast("1582-06-15T00:00:00Z") == nil)  // reform year → defers to Foundation
        #expect(fast("0000-01-01T00:00:00Z") == nil)  // year < 1 → defers
        // …and every one it resolves matches Foundation bit-for-bit.
        for s in ["1000-06-15T12:34:56Z", "0100-01-01T00:00:00Z", "1581-12-31T23:59:59Z", "1580-02-29T00:00:00Z"] {
            #expect(agrees(s), "pre-1583 disagreement for \(s)")
        }
    }

    @Test func matchesFoundationOnEdgeAndInvalidInputs() {
        let cases = [
            "2020-01-01T00:00:00Z", "1970-01-01T00:00:00Z", "2001-01-01T00:00:00Z",
            "2020-02-29T12:34:56Z",  // valid leap day
            "2019-02-29T00:00:00Z",  // Feb 29 in a non-leap year — both must reject
            "2000-02-29T00:00:00Z",  // 2000 is a leap year (÷400)
            "1900-02-29T00:00:00Z",  // 1900 is NOT a leap year (÷100 not ÷400)
            "2020-13-01T00:00:00Z", "2020-00-01T00:00:00Z", "2020-01-32T00:00:00Z",
            "2020-01-00T00:00:00Z", "2020-01-01T24:00:00Z", "2020-01-01T00:60:00Z",
            "2020-01-01T00:00:60Z",  // second 60 — fast path rejects, Foundation decides
            "2020-01-01T00:00:00",  // missing Z
            "2020-01-01T00:00:00.5Z",  // fractional seconds
            "2020-01-01T00:00:00+00:00",  // numeric offset
            "2020-1-1T0:0:0Z",  // not zero-padded
            "2020-01-01t00:00:00z",  // lowercase separators
            "not a date", "", "2020-01-01", "2020-01-01T00:00:00ZZ",
            "9999-12-31T23:59:59Z", "0001-01-01T00:00:00Z", "0000-01-01T00:00:00Z"
        ]
        for s in cases {
            #expect(agrees(s), "disagreement for \(s)")
        }
    }

    /// Sweep instants across the full 4-digit-year range (0001–9999), format each canonically, and
    /// require the fast parse to match Foundation bit-for-bit. Covers leap years, month/day boundaries,
    /// and every hour/minute/second combination the step lands on.
    @Test func matchesFoundationAcrossFourDigitYears() {
        let style = Date.ISO8601FormatStyle()
        var mismatches: [String] = []
        // year 0001-01-01 ≈ -62_135_596_800 ; year 9999-12-31 ≈ +253_402_300_799 (timeIntervalSince1970)
        var t = -62_135_596_800
        let end = 253_402_300_799
        let step = 39_916_801  // a prime-ish step → ~7900 samples, varied H:M:S
        while t <= end {
            let s = Date(timeIntervalSince1970: Double(t)).formatted(style)
            if !agrees(s) { mismatches.append(s) }
            t += step
        }
        #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(5))")
    }

    /// Randomized differential fuzz: random instants → canonical string → compare parses.
    @Test func randomizedDifferentialFuzz() {
        let style = Date.ISO8601FormatStyle()
        var rng = SystemRandomNumberGenerator()
        var mismatches: [String] = []
        for _ in 0 ..< 200_000 {
            let t = Int.random(in: -62_135_596_800 ... 253_402_300_799, using: &rng)
            let s = Date(timeIntervalSince1970: Double(t)).formatted(style)
            if !agrees(s) {
                mismatches.append(s)
                if mismatches.count > 5 { break }
            }
        }
        #expect(mismatches.isEmpty, "mismatches: \(mismatches)")
    }

    /// End-to-end: decoding `[Date]` through the public ADJSON decoder must equal Foundation's decoder.
    @Test func endToEndDecodeMatchesFoundation() throws {
        var strings: [String] = []
        for i in 0 ..< 500 {
            let t = Double(1_500_000_000 + i * 86_401)
            let iso: String = Date(timeIntervalSince1970: t).formatted(.iso8601)
            strings.append("\"\(iso)\"")
        }
        // Exercise the tape decoder's kernel-defer fallback too: a pre-1583 (Julian) date through the
        // byte fast path, and a fractional-seconds date the kernel defers on (→ String + Foundation).
        strings.append("\"1500-06-15T10:20:30Z\"")  // Julian era through the tape path
        strings.append("\"2021-03-14T15:09:26.5Z\"")  // fractional → kernel defers → Foundation
        let json = "[" + strings.joined(separator: ",") + "]"
        let data = Data(json.utf8)

        var ours = ADJSON.JSONDecoder()
        ours.dateDecodingStrategy = .iso8601
        let f = Foundation.JSONDecoder()
        f.dateDecodingStrategy = .iso8601

        let oursDates = try ours.decode([Date].self, from: data)
        let fDates = try f.decode([Date].self, from: data)
        // Not a wall-clock assertion: `timeIntervalSinceReferenceDate` is only the value accessor
        // used to compare two decoded `[Date]` arrays. Nothing here measures elapsed time, so the
        // comparison is fully deterministic.
        let oursValues = oursDates.map(\.timeIntervalSinceReferenceDate)  // lint:allow
        let foundationValues = fDates.map(\.timeIntervalSinceReferenceDate)  // lint:allow
        #expect(oursValues == foundationValues)
    }
}
