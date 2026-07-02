import ADTestKit
import Foundation
import Testing

@testable import ADJSON

// Parity oracle for numbers: the same JSON, decoded through every path — raw bytes, a `JSONValue`
// tree, and the `@JSONCodable` fast path — must agree with each other and (where the representation
// allows) with Foundation's `JSONDecoder`. Encode paths must emit byte-identical output. The byte
// path is the reference: it reads the original number lexeme, so it matches Foundation on int-vs-double
// classification and keeps `Decimal` exact. A materialized `JSONValue` is intentionally lossy (it holds
// `Int64`/`Double`), so its precision limit is asserted explicitly rather than papered over.
struct CrossPathNumberParityTests {
    private static let posix = Locale(identifier: "en_US_POSIX")

    // Outcome of a decode attempt, comparable across paths: a success value, or "threw".
    private enum Outcome<T: Equatable>: Equatable {
        case value(T)
        case failed
    }
    private func outcome<T: Equatable>(_ body: () throws -> T) -> Outcome<T> {
        do { return .value(try body()) } catch { return .failed }
    }

    // MARK: Integer decode — bytes match Foundation; the JSONValue tree matches the bytes.

    // Arrays avoid top-level-fragment differences between decoders; one element exercises the coercion.
    @Test(arguments: ["100", "0", "-5", "100.0", "1e2", "3.5", "9007199254740993"])
    func intDecodeAgreesAcrossPaths(_ literal: String) {
        let json = "[\(literal)]"
        let data = Data(json.utf8)
        let foundation = outcome { try Foundation.JSONDecoder().decode([Int].self, from: data) }
        let bytes = outcome { try ADJSON.JSONDecoder().decode([Int].self, from: data) }
        let tree = outcome { try ADJSON.JSONDecoder().decode([Int].self, from: try JSONValue(parsing: json)) }
        #expect(bytes == foundation, "byte path vs Foundation diverged for \(literal): \(bytes) vs \(foundation)")
        #expect(tree == bytes, "JSONValue path vs byte path diverged for \(literal): \(tree) vs \(bytes)")
    }

    // MARK: Decimal — the byte/tape path is exact; the JSONValue path carries only Double precision.

    @Test func decimalBytePathIsExact() throws {
        let literal = "0.123456789012345678901234567890"  // 30 sig digits: beyond Double, within Decimal
        let exact = Decimal(string: literal, locale: Self.posix)!
        let viaBytes = try ADJSON.JSONDecoder().decode([Decimal].self, from: Data("[\(literal)]".utf8))
        #expect(viaBytes.first == exact)
        // The lazy cursor's `decimal` accessor reads the same source lexeme — also exact.
        let doc = try ADJSON.parse("[\(literal)]")
        #expect(doc.root[index: 0].decimal == exact)
        // Foundation special-cases Decimal to full precision too.
        let viaFoundation = try Foundation.JSONDecoder().decode([Decimal].self, from: Data("[\(literal)]".utf8))
        #expect(viaBytes.first == viaFoundation.first)
    }

    @Test func decimalThroughJSONValueIsLossy() throws {
        let literal = "0.123456789012345678901234567890"
        let exact = Decimal(string: literal, locale: Self.posix)!
        let tree = try JSONValue(parsing: "[\(literal)]")
        let viaTree = try ADJSON.JSONDecoder().decode([Decimal].self, from: tree)
        // JSONValue dropped the source lexeme, so Decimal reflects the Double's shortest form, not the
        // 30-digit source. This is the documented precision boundary: read Decimal from bytes/the tape.
        #expect(viaTree.first != exact)
        let doubleShortest = Decimal(string: Double(literal)!.description, locale: Self.posix)!
        #expect(viaTree.first == doubleShortest)
    }

    // MARK: Large integers beyond Int64 — exact on the byte/tape path.

    @Test func uint64BeyondInt64DecodesExactlyFromBytes() throws {
        let big: UInt64 = 18_000_000_000_000_000_000  // > Int64.max, < UInt64.max
        let viaBytes = try ADJSON.JSONDecoder().decode([UInt64].self, from: Data("[\(big)]".utf8))
        #expect(viaBytes.first == big)
    }

    // MARK: Encode — the value-tree writer and the lazy-cursor writer are byte-identical.

    @Test func encodeValueAndCursorAreByteIdentical() throws {
        let value: JSONValue = .object([
            "i": .int(42), "d": .number(3.5), "big": .int(9_007_199_254_740_993),
            "neg": .number(-0.25), "arr": .array([.int(1), .number(2.5), .int(-3)])
        ])
        let prettySorted = JSONEncodingOptions(keyOrder: .sorted, prettyPrinted: true)
        for options in [JSONEncodingOptions.rfc8259, .javaScript, prettySorted] {
            let viaValue = try value.encodedBytes(options: options)
            let viaCursor = try ADJSON.parse(viaValue).root.encodedBytes(options: options)
            #expect(viaValue == viaCursor, "value vs cursor encode diverged")
        }
    }

    // MARK: @JSONCodable fast path agrees with Foundation, numerically, and round-trips.

    @JSONCodable struct Nums: Codable, Equatable {
        var i: Int
        var u: UInt64
        var d: Double
        var f: Float
    }

    @Test func fastPathNumbersMatchFoundation() throws {
        let json = #"{"i":-7,"u":18000000000000000000,"d":3.5,"f":0.5}"#
        let data = Data(json.utf8)
        let viaFast = try ADJSON.JSONDecoder().decode(Nums.self, from: data)
        let viaFoundation = try Foundation.JSONDecoder().decode(Nums.self, from: data)
        #expect(viaFast == viaFoundation)
        let reencoded = try ADJSON.JSONEncoder().encode(viaFast)
        #expect(try ADJSON.JSONDecoder().decode(Nums.self, from: reencoded) == viaFast)
    }

    // MARK: SAX — the pull reader exposes the exact number lexeme the Double payload would round.

    @Test func saxCurrentNumberLexemeRecoversExactSource() throws {
        var reader = JSONEventReader(#"[123456789012345678901234567890,9007199254740993,"x",3.5]"#)
        let begin: JSONEvent? = try reader.next()
        expectEqual(begin, .beginArray)
        expectNil(reader.currentNumberLexeme)  // a container is not a number
        _ = try reader.next()  // 30-digit number — beyond Double, exact in the lexeme
        expectEqual(reader.currentNumberLexeme, "123456789012345678901234567890")
        _ = try reader.next()  // 9007199254740993 (> 2^53) — recoverable as an exact Int64
        expectEqual(reader.currentNumberLexeme, "9007199254740993")
        let recovered: Int64? = Int64(reader.currentNumberLexeme ?? "")
        expectEqual(recovered, 9_007_199_254_740_993)
        let stringEvent: JSONEvent? = try reader.next()
        expectEqual(stringEvent, .string("x"))
        expectNil(reader.currentNumberLexeme)  // a non-number event clears it
        _ = try reader.next()  // 3.5
        expectEqual(reader.currentNumberLexeme, "3.5")
    }

    // MARK: Fixed scratch-buffer bounds — exercised at their widest, so an off-by-one would corrupt.

    @Test func integerScratchBufferHandlesWidestMagnitudes() {
        func encode<T: FixedWidthInteger>(_ v: T) -> String {
            var bytes: [UInt8] = []
            JSONOutput.appendInteger(v, to: &bytes)
            return String(decoding: bytes, as: UTF8.self)
        }
        #expect(encode(UInt64.max) == "18446744073709551615")
        #expect(encode(Int64.min) == "-9223372036854775808")
        // 39 digits — the widest case the 40-byte `appendMagnitude` scratch must hold.
        #expect(encode(UInt128.max) == "340282366920938463463374607431768211455")
        #expect(encode(Int128.min) == "-170141183460469231731687303715884105728")
    }

    @Test func doubleScratchBufferHandlesExtremes() throws {
        let extremes: [Double] = [
            .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNonzeroMagnitude, .leastNormalMagnitude,
            .pi, 0, -0.0
        ]
        for d in extremes {
            let s = String(decoding: try JSONValue.number(d).encodedBytes(), as: UTF8.self)
            #expect(Double(s) == d, "round-trip failed for \(d): encoded \(s)")  // shortest form fit the 24-byte gather
        }
    }

    // MARK: Float decode is single-rounded — no double rounding (decimal→Double→Float).

    // The bug: `Float` was decoded as `Float(Double(lexeme))` — the decimal was parsed to `Double`,
    // then narrowed to `Float`, rounding twice. For some decimals that lands on a DIFFERENT `Float`
    // bit pattern than rounding the decimal straight to the nearest `Float`. Decode must equal
    // `Float("<digits>")` (the correctly-rounded-nearest Float), NOT `Float(Double("<digits>"))`.

    // A one-field `@JSONCodable` carrier so the fast (`_FastDecodeCursor`) Float path is exercised.
    @JSONCodable struct FloatBox: Codable, Equatable { var f: Float }

    // Decimals where `Float(Double(s)) != Float(s)` — found by sampling near Float rounding boundaries.
    // Each is a literal where the old (double-rounding) decode produced the wrong `Float` bit pattern.
    private static let doubleRoundingDivergent: [String] = [
        "1.4390599421183441e-16",
        "5.9058874869559463e-13",
        "2.9142915511370937e-11",
        "3.8608163333009315e-09",
        "8.1179565292188727e-09",
        "5.1856581292405555e+17",
        "1.1806857639640219e+24",
        "5.009292489747905e+26",
        "1.6817101679662769e+29"
    ]

    // Sanity-check the fixtures actually exercise the bug: each must round to different Float bits the
    // two ways. (If a future toolchain changed std-lib rounding so one no longer diverges, this flags it.)
    @Test func divergentFixturesActuallyDoubleRound() {
        for s in Self.doubleRoundingDivergent {
            let direct = Float(s)!
            let viaDouble = Float(Double(s)!)
            #expect(
                direct.bitPattern != viaDouble.bitPattern,
                "fixture \(s) no longer diverges: Float(s) and Float(Double(s)) agree — pick another")
        }
    }

    // Decode each divergent decimal through EVERY live Float path and assert it equals the
    // correctly-rounded-nearest `Float(s)` (single rounding), not the old `Float(Double(s))`.
    @Test func floatDecodeIsSingleRoundedAcrossPaths() throws {
        for s in Self.doubleRoundingDivergent {
            let expected = Float(s)!  // correctly-rounded-nearest Float of the source decimal
            let wrong = Float(Double(s)!)  // what the old double-rounding decode produced

            // Byte/tape Codable path (single-value container via [Float]).
            let bytes = try ADJSON.JSONDecoder().decode([Float].self, from: Data("[\(s)]".utf8))
            #expect(bytes.first?.bitPattern == expected.bitPattern, "byte path double-rounded \(s)")
            #expect(bytes.first?.bitPattern != wrong.bitPattern || expected.bitPattern == wrong.bitPattern)

            // @JSONCodable fast path (_FastDecodeCursor.currentFloat).
            let fast = try ADJSON.JSONDecoder().decode(FloatBox.self, from: Data(#"{"f":\#(s)}"#.utf8))
            #expect(fast.f.bitPattern == expected.bitPattern, "fast path double-rounded \(s)")

            // Lazy cursor accessor (`JSON.float`), which re-parses the source lexeme.
            let doc = try ADJSON.parse("[\(s)]")
            #expect(doc.root[index: 0].float?.bitPattern == expected.bitPattern, "JSON.float double-rounded \(s)")
        }
    }

    // Encode→decode must reproduce the exact `Float` bit pattern. Covers the divergent set plus a
    // randomized sweep of arbitrary `Float`s: encode (shortest `Float.description`), decode, compare bits.
    @Test func floatEncodeDecodeIsBitIdentical() throws {
        var sample: [Float] = [
            0, -0.0, 1, -1, .pi, .leastNonzeroMagnitude, .leastNormalMagnitude,
            .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 0.1, 0.2, 0.3, 1.0 / 3.0,
            Float(bitPattern: 0x0000_0001), Float(bitPattern: 0x007F_FFFF)  // smallest subnormal / largest subnormal
        ]
        sample += Self.doubleRoundingDivergent.map { Float($0)! }

        var rng = SystemRandomNumberGenerator()
        for _ in 0 ..< 20_000 {
            let f = Float(bitPattern: UInt32.random(in: 0 ... 0xFFFF_FFFF, using: &rng))
            if f.isFinite { sample.append(f) }
        }

        for f in sample {
            let json = try ADJSON.JSONEncoder().encode(FloatBox(f: f))
            // The encoder emits the shortest `Float` decimal; decode must invert it to the same bits.
            let viaBytes = try ADJSON.JSONDecoder().decode(FloatBox.self, from: json)
            #expect(
                viaBytes.f.bitPattern == f.bitPattern,
                "round-trip lost bits for \(f) → \(String(decoding: json, as: UTF8.self))")
            // Re-decode through the single-value/array path too.
            let arr = try ADJSON.JSONEncoder().encode([f])
            let viaArray = try ADJSON.JSONDecoder().decode([Float].self, from: arr)
            #expect(viaArray.first?.bitPattern == f.bitPattern, "array round-trip lost bits for \(f)")
        }
    }

    // Float nonconforming-float / special values still decode at Float width (not via a narrowed Double).
    // A plain `Codable` carrier routes through the generic container → `decodeFloat`, which (unlike the
    // `@JSONCodable` fast path, by design) honours the nonConformingFloat string strategy.
    private struct PlainFloatBox: Codable, Equatable { var f: Float }

    @Test func floatSpecialValuesDecode() throws {
        // ±0 keeps its sign bit.
        let negZero = try ADJSON.JSONDecoder().decode([Float].self, from: Data("[-0.0]".utf8)).first!
        #expect(negZero.bitPattern == Float(-0.0).bitPattern)
        let posZero = try ADJSON.JSONDecoder().decode([Float].self, from: Data("[0.0]".utf8)).first!
        #expect(posZero.bitPattern == Float(0).bitPattern)

        // nonConformingFloat string literals decode to Float-width inf/nan.
        var decoder = ADJSON.JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
        let inf = try decoder.decode(PlainFloatBox.self, from: Data(#"{"f":"Inf"}"#.utf8))
        #expect(inf.f == .infinity)
        let negInf = try decoder.decode(PlainFloatBox.self, from: Data(#"{"f":"-Inf"}"#.utf8))
        #expect(negInf.f == -.infinity)
        let nan = try decoder.decode(PlainFloatBox.self, from: Data(#"{"f":"NaN"}"#.utf8))
        #expect(nan.f.isNaN)
    }

    // Double decode must be UNCHANGED by the Float fix: the same divergent decimals decode to the
    // ordinary `Double(s)`, and the byte path still equals Foundation's `JSONDecoder`.
    @Test func doubleDecodeIsUnchanged() throws {
        for s in Self.doubleRoundingDivergent {
            let expected = Double(s)!
            let viaBytes = try ADJSON.JSONDecoder().decode([Double].self, from: Data("[\(s)]".utf8))
            #expect(viaBytes.first == expected, "Double byte-path decode changed for \(s)")
            let viaFoundation = try Foundation.JSONDecoder().decode([Double].self, from: Data("[\(s)]".utf8))
            #expect(viaBytes.first == viaFoundation.first, "Double byte path diverged from Foundation for \(s)")
            // The lazy cursor's Double accessor is likewise untouched.
            let doc = try ADJSON.parse("[\(s)]")
            #expect(doc.root[index: 0].double == expected)
        }
    }
}
