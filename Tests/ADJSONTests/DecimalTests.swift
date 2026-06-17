import ADJSON
import Foundation
import Testing

// Exact-decimal support: the lazy `JSON.decimal` reads the original number lexeme (preserving values
// `Double` would round), and Codable decode/encode special-case `Decimal` to match Foundation.
@Suite("Decimal")
struct DecimalTests {
    @Test func jsonDecimalPreservesLargeIntegerExactly() throws {
        let big = "123456789012345678901234567890"  // 30 digits — beyond Int64 and 2^53
        let node = try ADJSON.parse("{\"n\":\(big)}").root.n
        let exact = try #require(node.decimal)
        #expect(exact == Decimal(string: big))
        // The Double path rounds; reading the lexeme as Decimal does not — the whole point.
        let viaDouble = Decimal(try #require(node.double))
        #expect(exact != viaDouble)
    }

    @Test func jsonDecimalPreservesFractionExactly() throws {
        #expect(try ADJSON.parse("0.1").root.decimal == Decimal(string: "0.1"))
        // A fraction with more significant digits than a Double can hold stays exact via the lexeme path.
        let precise = "0.12345678901234567890123"  // 23 significant digits (> Double's ~17)
        #expect(try ADJSON.parse(precise).root.decimal == Decimal(string: precise))
    }

    @Test func jsonDecimalNilForNonNumberAndOutOfRange() throws {
        #expect(try ADJSON.parse(#""text""#).root.decimal == nil)
        #expect(try ADJSON.parse("true").root.decimal == nil)
        #expect(try ADJSON.parse("1e1000").root.decimal == nil)  // exponent far beyond Decimal's range
    }

    @Test func jsonValueDecimalFromMaterializedValue() {
        #expect(JSONValue.int(42).decimal == Decimal(42))
        #expect(JSONValue.number(0.5).decimal == Decimal(string: "0.5"))
        #expect(JSONValue.string("x").decimal == nil)
    }

    private struct Money: Codable, Equatable {
        var price: Decimal
        var qty: Decimal
    }

    @Test func codableDecodeDecimalMatchesFoundation() throws {
        let json = Data(#"{"price":12345678901234567890.12,"qty":0.1}"#.utf8)
        let viaADJSON = try ADJSON.JSONDecoder().decode(Money.self, from: json)
        let viaFoundation = try Foundation.JSONDecoder().decode(Money.self, from: json)
        #expect(viaADJSON == viaFoundation)
        #expect(viaADJSON.price == Decimal(string: "12345678901234567890.12"))
        #expect(viaADJSON.qty == Decimal(string: "0.1"))
    }

    @Test func codableEncodeDecimalAsNumber() throws {
        let value = Money(price: try #require(Decimal(string: "19.99")), qty: try #require(Decimal(string: "0.1")))
        let data = try ADJSON.JSONEncoder().encode(value)
        // ADJSON emits Decimals as JSON *numbers* (like Foundation), not Decimal's keyed Codable form,
        // and in deterministic declaration order (Foundation's key order is unspecified, so a byte
        // comparison isn't meaningful — value parity is checked by the cross-decode below).
        #expect(String(decoding: data, as: UTF8.self) == #"{"price":19.99,"qty":0.1}"#)
        #expect(try Foundation.JSONDecoder().decode(Money.self, from: data) == value)
    }

    @Test func fastDecimalParityWithFoundationAcrossCases() throws {
        let posix = Locale(identifier: "en_US_POSIX")
        // Exercises the UInt128 fast path (short, long up to 38 digits, fractions, signs, exponents)
        // and the >38-digit / out-of-range-exponent fallback — every case must equal Decimal(string:).
        let cases = [
            "0", "-0", "7", "-7", "0.1", "19.99", "-1234.5678",
            "12345678901234567890",  // 20 digits (past UInt64)
            "1234567890123456789012345678.1234",  // 32 significant digits
            "99999999999999999999999999999999999999",  // 38 nines — Decimal's capacity
            "123456789012345678901234567890123456789",  // 39 digits → fallback
            "1e5", "1.5e10", "-2.5e-7", "3.14159E2", "1E-30", "0.000000000000000000001",
            "100000000000000000000",
        ]
        let decoded = try ADJSON.JSONDecoder().decode(
            [Decimal].self, from: Data(("[" + cases.joined(separator: ",") + "]").utf8))
        for (i, c) in cases.enumerated() {
            #expect(decoded[i] == Decimal(string: c, locale: posix), "mismatch for \(c)")
        }
    }

    @Test func decimalRoundTripsExactly() throws {
        let original = Money(
            price: try #require(Decimal(string: "0.1")),
            qty: try #require(Decimal(string: "123456789012345678901234567890")))
        let data = try ADJSON.JSONEncoder().encode(original)
        let back = try ADJSON.JSONDecoder().decode(Money.self, from: data)
        #expect(back == original)
    }
}
