import Testing

@testable import ADJSON

// Parse / number-classification parity with SQLite (`.strict`, i.e. standard non-I-JSON).
//
// `JSONValue` is `Int64`-bounded, so the rule (per the ADSQL consumer) is: `.int` iff an integer
// literal (no `.`/`e`/`E`) that fits `Int64`, otherwise `.number(Double)` — including a magnitude that
// overflows `Int64`, which SQLite accepts as a (lossy) real rather than rejecting. SQLite's own
// `json_type` LABELS such a literal `integer`, but that shape label is the consumer's mapping; what
// ADJSON owns is the value model, where an over-large integer can only be a `Double`.
@Suite("SQLite number/validity parity")
struct SQLiteNumberParityTests {
    private func kind(_ s: String) throws -> String {
        switch JSONValue(try ADJSON.parse(s).root) {
        case .int: return "int"
        case .number: return "real"
        default: return "other"
        }
    }

    @Test func integerVsRealClassification() throws {
        #expect(try kind("5") == "int")
        #expect(try kind("-5") == "int")
        #expect(try kind("0") == "int")
        #expect(try kind("9223372036854775807") == "int")  // Int64.max
        #expect(try kind("-9223372036854775808") == "int")  // Int64.min
        #expect(try kind("5.0") == "real")
        #expect(try kind("1E2") == "real")  // exponent ⇒ real
        #expect(try kind("1e308") == "real")
        #expect(try kind("9223372036854775808") == "real")  // Int64.max + 1 ⇒ real (overflow, not rejected)
        #expect(try kind("100000000000000000000") == "real")  // 1e20, 21 digits ⇒ real
    }

    // SQLite `json_valid` parity: bare top-level scalars are valid, leading/trailing whitespace is
    // allowed, trailing non-whitespace is invalid, and an over-large integer literal is accepted.
    @Test func validityMatchesSQLite() {
        func valid(_ s: String) -> Bool { (try? ADJSON.parse(s)) != nil }
        #expect(valid("5"))
        #expect(valid("5.0"))
        #expect(valid("\"x\""))
        #expect(valid("true"))
        #expect(valid("false"))
        #expect(valid("null"))
        #expect(valid("  5"))  // leading whitespace
        #expect(valid("5  "))  // trailing whitespace
        #expect(valid("\t\n 5 \r"))  // assorted JSON whitespace
        #expect(valid("100000000000000000000"))  // overflow integer accepted
        #expect(!valid("5 x"))  // trailing non-whitespace
        #expect(!valid("5,"))  // trailing garbage
        #expect(!valid(""))  // empty
    }
}
