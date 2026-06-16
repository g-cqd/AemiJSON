import Testing

@testable import ADJSON

// Byte-for-byte parity of `NumberFormat.sqlitePrintfG` (the `.sqlite` preset) with SQLite's JSON
// output. Expected strings were generated from `sqlite3 :memory: "SELECT json_quote(<v>);"` on
// SQLite 3.54.0; the format is SQLite's `%!.15g` (15 significant figures, %g fixed/exponential
// selection, a kept fractional digit, plus-or-minus 0.0 -> 0.0). If a future SQLite changes its float
// rendering, regenerate this table.
private let sqliteFloatCorpus: [(Double, String)] = [
    (0.0, "0.0"), (-0.0, "0.0"), (1.0, "1.0"), (-1.0, "-1.0"), (5.0, "5.0"), (100.0, "100.0"),
    (0.1, "0.1"), (0.2, "0.2"), (0.3, "0.3"), (0.5, "0.5"), (1.5, "1.5"), (-1.5, "-1.5"),
    (3.14159, "3.14159"), (2.718281828459045, "2.71828182845905"),
    (1.0 / 3.0, "0.333333333333333"), (2.0 / 3.0, "0.666666666666667"),
    (1e-4, "0.0001"), (1e-5, "1.0e-05"), (1e-6, "1.0e-06"), (1e-7, "1.0e-07"),
    (-0.000001, "-1.0e-06"), (2.5e-8, "2.5e-08"), (1e-300, "1.0e-300"),
    (1.234_567_890_123_45e-300, "1.23456789012345e-300"), (4.9e-324, "4.94065645841247e-324"),
    (12345.6789, "12345.6789"), (0.000123, "0.000123"), (1_000_000.0, "1000000.0"),
    (1e15, "1.0e+15"), (1e16, "1.0e+16"), (1e20, "1.0e+20"), (1e21, "1.0e+21"),
    (-1e20, "-1.0e+20"), (1e308, "1.0e+308"),
    (123_456_789_012_345.0, "123456789012345.0"), (9_007_199_254_740_992.0, "9.00719925474099e+15"),
    (1_234_567_890_123_456_789.0, "1.23456789012346e+18"), (99_999_999_999_999_999.0, "1.0e+17"),
]

@Suite("SQLite encoder parity")
struct SQLiteEncoderTests {
    @Test(arguments: sqliteFloatCorpus)
    func sqlitePrintfGMatchesSQLite(_ pair: (Double, String)) throws {
        let bytes = try JSONValue.number(pair.0).encodedBytes(options: .sqlite)
        #expect(String(decoding: bytes, as: UTF8.self) == pair.1)
    }

    // The number format is the Double-only path: integers keep their exact decimal form.
    @Test func integersUnaffectedByNumberFormat() throws {
        let i = try String(decoding: JSONValue.int(42).encodedBytes(options: .sqlite), as: UTF8.self)
        let big = try String(decoding: JSONValue.int(-9_000_000_000).encodedBytes(options: .sqlite), as: UTF8.self)
        #expect(i == "42")
        #expect(big == "-9000000000")
    }

    // String escaping under the `.sqlite` preset matches SQLite's `json_quote`: short forms for
    // backspace/formfeed/newline/return/tab, escaped quote and backslash, slashes raw. Input and
    // expected are byte arrays so no control-char or backslash escapes live in the source. Input:
    // a / b, LF, TAB, quote, backslash, backspace(8), formfeed(12), CR. Expected from:
    //   SELECT json_quote('a/b'||char(10)||char(9)||char(34)||char(92)||char(8)||char(12)||char(13));
    @Test func stringEscapesMatchSQLite() throws {
        let inputBytes: [UInt8] = [0x61, 0x2F, 0x62, 10, 9, 34, 92, 8, 12, 13]
        let raw = String(decoding: inputBytes, as: UTF8.self)
        let out = Array(try JSONValue.string(raw).encodedBytes(options: .sqlite))
        // Bytes of the JSON string  "a/b" + escaped LF, TAB, quote, backslash, backspace, formfeed, CR.
        let bs = UInt8(0x5C)  // backslash
        let q = UInt8(0x22)  // double quote
        let expected: [UInt8] =
            [q, 0x61, 0x2F, 0x62]
            + [bs, 0x6E, bs, 0x74]  // \n \t
            + [bs, q, bs, bs]  // \" \\
            + [bs, 0x62, bs, 0x66]  // \b \f
            + [bs, 0x72, q]  // \r "
        #expect(out == expected)
    }

    // A nested value round-trips through the SQLite preset (object/array/number/int/string).
    @Test func nestedValueMatchesMinifiedSQLiteShape() throws {
        let v: JSONValue = .object(["a": .array([.int(1), .number(2.5), .string("x/y")]), "b": .number(1e20)])
        let s = try String(decoding: v.encodedBytes(options: .sqlite), as: UTF8.self)
        #expect(s == #"{"a":[1,2.5,"x/y"],"b":1.0e+20}"#)
    }
}
