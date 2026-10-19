import AemiJSON
import Foundation
import Testing

@testable import AemiJSONCore

// JSON5 numbers follow the ECMAScript 5.1 NumericLiteral grammar, where a DecimalIntegerLiteral is `0` or
// a non-zero digit followed by digits. `01`, `00`, `-01` and `01.5` are therefore not JSON5 numbers, and
// the reference implementation (`json5` 2.2.3) rejects every one of them (issue #2). The tape scanner and
// the shared SAX lexeme scanner both accepted them; both must reject them, in every route.
//
// Probed against `json5` 2.2.3 under bun: `0.5`, `0`, `-0`, `0e1`, `0.`, `-.01`, `0x1F` and `0x01` are
// accepted; `01`, `00`, `-01`, `+01`, `01.5`, `00.5`, `01e5`, `[01]` and `[007]` are `invalid character`.

struct JSON5LeadingZeroTests {
    @Test(arguments: [
        "{a: 01}", "{a: 00}", "{a: -01}", "{a: +01}", "{a: 01.5}", "{a: 00.5}", "{a: 01e5}", "{a: -00}",
        "[01]", "[007]", "[0123456789]", "[1, 01]", "{a: 0, b: 01}", "01", "-01", "00"
    ])
    func aDecimalWithALeadingZeroIsRejectedByEveryRoute(_ document: String) {
        expectEveryRoute(document, reads: nil)
    }

    @Test(arguments: [
        ("{a: 0.5}", JSONValue.object(["a": .number(0.5)])),
        ("{a: 0}", .object(["a": .int(0)])),
        ("{a: -0}", .object(["a": .number(-0.0)])),
        ("{a: +0}", .object(["a": .int(0)])),
        ("{a: 0e1}", .object(["a": .number(0)])),
        ("{a: 0E+5}", .object(["a": .number(0)])),
        ("{a: 0.}", .object(["a": .number(0)])),
        ("{a: 0.0}", .object(["a": .number(0)])),
        ("{a: -.01}", .object(["a": .number(-0.01)])),
        ("{a: 0x1F}", .object(["a": .int(31)])),
        ("{a: 0x01}", .object(["a": .int(1)])),
        ("{a: -0x0F}", .object(["a": .int(-15)])),
        ("{a: 0X0}", .object(["a": .int(0)])),
        ("[0,1,10,100]", .array([.int(0), .int(1), .int(10), .int(100)])),
        ("[0.01, 10.01, 100e-2]", .array([.number(0.01), .number(10.01), .number(1)])),
        ("0", .int(0))
    ])
    func aZeroThatIsNotFollowedByADigitIsStillANumber(_ document: String, _ expected: JSONValue) {
        expectEveryRoute(document, reads: expected)
    }

    @Test func aLeadingZeroSplitAcrossChunksIsRejectedNotJoined() {
        // `0` ends the first chunk, so the push reader cannot yet know whether a digit follows. When one
        // does, the number is `01`, which is invalid, at every cut.
        let document = Array("[0123]".utf8)
        for cut in 0 ... document.count {
            let value = ReadRoute.pushValue(of: document, chunks: [0 ..< cut, cut ..< document.count], options: .json5)
            #expect(value == nil, "[0123] cut at byte \(cut) read as \(String(describing: value))")
        }
    }

    @Test func aZeroFollowedByADotOrExponentSplitAcrossChunksIsStillAccepted() {
        let documents: [(text: String, expected: JSONValue)] = [
            ("[0.5]", .array([.number(0.5)])), ("[0e1]", .array([.number(0)])), ("[0x1F]", .array([.int(31)]))
        ]
        for (text, expected) in documents {
            let document = Array(text.utf8)
            for cut in 0 ... document.count {
                let value = ReadRoute.pushValue(
                    of: document, chunks: [0 ..< cut, cut ..< document.count], options: .json5)
                #expect(value == expected, "\(text) cut at byte \(cut) read as \(String(describing: value))")
            }
        }
    }

    private func lexeme(_ text: String, complete: Bool) -> JSONNumber.ScanOutcome {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return .invalid }
            return JSONNumber.scanJSON5Lexeme(base, 0, bytes.count, complete: complete)
        }
    }

    @Test(arguments: ["01]", "00]", "-01]", "+007,", "01.5]", "01e1]"])
    func theSharedLexemeScannerRejectsALeadingZeroWhetherOrNotMoreBytesMayArrive(_ text: String) {
        #expect(lexeme(text, complete: false) == .invalid)
        #expect(lexeme(text, complete: true) == .invalid)
    }

    @Test func theSharedLexemeScannerStillScansAZeroThatIsNotFollowedByADigit() {
        #expect(lexeme("0", complete: false) == .incomplete)  // a digit may still follow
        #expect(lexeme("0", complete: true) == .ok(1))
        #expect(lexeme("0]", complete: false) == .ok(1))
        #expect(lexeme("0.5]", complete: false) == .ok(3))
        #expect(lexeme("0x01]", complete: false) == .ok(4))
    }

    @Test func lenientStillAcceptsALeadingZeroAndStrictStillRejectsIt() {
        // The check is JSON5's own: the lenient grammar documents leading zeros as accepted, and strict
        // rejected them already.
        expectEveryRoute("[01, 007, -01.5]", options: .lenient, reads: .array([.int(1), .int(7), .number(-1.5)]))
        expectEveryRoute("[01]", options: .strict, reads: nil)
    }

    @Test func theDecoderRejectsALeadingZeroInJSON5() throws {
        struct Settings: Decodable, Equatable { let a: Double }
        var decoder = AemiJSON.JSONDecoder()
        decoder.allowsJSON5 = true
        #expect(try decoder.decode(Settings.self, from: Data("{a: 0.5}".utf8)) == Settings(a: 0.5))
        #expect(throws: JSONError.self) { try decoder.decode(Settings.self, from: Data("{a: 01.5}".utf8)) }
        #expect(throws: JSONError.self) { try decoder.decode(Settings.self, from: Data("{a: 01}".utf8)) }
    }
}
