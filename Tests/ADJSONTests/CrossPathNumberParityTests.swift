import Foundation
import Testing

@testable import ADJSON

// Parity oracle for numbers: the same JSON, decoded through every path — raw bytes, a `JSONValue`
// tree, and the `@JSONCodable` fast path — must agree with each other and (where the representation
// allows) with Foundation's `JSONDecoder`. Encode paths must emit byte-identical output. The byte
// path is the reference: it reads the original number lexeme, so it matches Foundation on int-vs-double
// classification and keeps `Decimal` exact. A materialized `JSONValue` is intentionally lossy (it holds
// `Int64`/`Double`), so its precision limit is asserted explicitly rather than papered over.
@Suite("Cross-path number parity")
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
            "neg": .number(-0.25), "arr": .array([.int(1), .number(2.5), .int(-3)]),
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
        #expect(try reader.next() == .beginArray)
        #expect(reader.currentNumberLexeme == nil)  // a container is not a number
        _ = try reader.next()  // 30-digit number — beyond Double, exact in the lexeme
        #expect(reader.currentNumberLexeme == "123456789012345678901234567890")
        _ = try reader.next()  // 9007199254740993 (> 2^53) — recoverable as an exact Int64
        #expect(reader.currentNumberLexeme == "9007199254740993")
        #expect(Int64(reader.currentNumberLexeme ?? "") == 9_007_199_254_740_993)
        #expect(try reader.next() == .string("x"))
        #expect(reader.currentNumberLexeme == nil)  // a non-number event clears it
        _ = try reader.next()  // 3.5
        #expect(reader.currentNumberLexeme == "3.5")
    }
}
