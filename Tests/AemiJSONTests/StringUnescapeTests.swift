import AemiJSON
import Foundation
import Testing

// `JSONString.unescape` / `unescapeJSON5` write the decoded bytes straight into the new string's
// storage instead of a scratch `[UInt8]` that `String(decoding:)` then copied. The output must not
// change, including for input only lenient mode lets through: truncated or unpaired `\u` escapes,
// unknown escapes, and ill-formed UTF-8, which the string initializer must repair the way
// `String(decoding:)` does. The references below are the previous implementations.

private func hexValue(_ byte: UInt8) -> UInt16 {
    switch byte {
        case 0x30 ... 0x39: return UInt16(byte - 0x30)
        case 0x41 ... 0x46: return UInt16(byte - 0x41 + 10)
        case 0x61 ... 0x66: return UInt16(byte - 0x61 + 10)
        default: return 0
    }
}

private func readHex4(_ b: [UInt8], _ start: Int, _ end: Int) -> UInt16 {
    var v: UInt16 = 0
    var k = start
    while k < min(start + 4, end) {
        v = (v << 4) | hexValue(b[k])
        k += 1
    }
    return v
}

private func appendUnicodeEscape(_ b: [UInt8], _ j: inout Int, _ end: Int, _ out: inout [UInt8]) {
    let hi = readHex4(b, j, end)
    j += 4
    var scalar = UInt32(hi)
    if hi >= 0xD800 && hi <= 0xDBFF, j + 1 < end, b[j] == 0x5C, b[j + 1] == 0x75 {
        let lo = readHex4(b, j + 2, end)
        if lo >= 0xDC00 && lo <= 0xDFFF {
            scalar = 0x10000 + ((UInt32(hi) - 0xD800) << 10) + (UInt32(lo) - 0xDC00)
            j += 6
        }
    }
    if let us = Unicode.Scalar(scalar) {
        Unicode.UTF8.encode(us) { out.append($0) }
    } else {
        out.append(contentsOf: [0xEF, 0xBF, 0xBD])
    }
}

private func referenceUnescape(_ b: [UInt8]) -> String {
    var out: [UInt8] = []
    var j = 0
    let end = b.count
    while j < end {
        if b[j] != 0x5C {
            out.append(b[j])
            j += 1
            continue
        }
        j += 1
        guard j < end else { break }
        let e = b[j]
        j += 1
        switch e {
            case 0x6E: out.append(0x0A)
            case 0x74: out.append(0x09)
            case 0x72: out.append(0x0D)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x75: appendUnicodeEscape(b, &j, end, &out)
            default: out.append(e)  // `"`, `\`, `/`, and anything lenient mode let through
        }
    }
    return String(decoding: out, as: UTF8.self)
}

private func referenceUnescapeJSON5(_ b: [UInt8]) -> String {
    var out: [UInt8] = []
    var j = 0
    let end = b.count
    loop: while j < end {
        if b[j] != 0x5C {
            out.append(b[j])
            j += 1
            continue
        }
        j += 1
        guard j < end else { break }
        let e = b[j]
        j += 1
        switch e {
            case 0x6E: out.append(0x0A)
            case 0x74: out.append(0x09)
            case 0x72: out.append(0x0D)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x76: out.append(0x0B)
            case 0x30: out.append(0x00)
            case 0x78:
                guard j + 1 < end else { break loop }
                let value = UInt8(truncatingIfNeeded: hexValue(b[j]) << 4 | hexValue(b[j + 1]))
                j += 2
                Unicode.UTF8.encode(Unicode.Scalar(value)) { out.append($0) }
            case 0x75: appendUnicodeEscape(b, &j, end, &out)
            case 0x0A: break
            case 0x0D: if j < end, b[j] == 0x0A { j += 1 }
            default:
                if e >= 0x80 {
                    let len = e >= 0xF0 ? 4 : (e >= 0xE0 ? 3 : 2)
                    if len == 3, e == 0xE2, j + 1 < end, b[j] == 0x80, b[j + 1] == 0xA8 || b[j + 1] == 0xA9 {
                        j += 2
                    } else {
                        out.append(e)
                        for _ in 1 ..< len where j < end {
                            out.append(b[j])
                            j += 1
                        }
                    }
                } else {
                    out.append(e)
                }
        }
    }
    return String(decoding: out, as: UTF8.self)
}

private func unescaped(_ body: [UInt8], json5: Bool) -> String {
    body.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return "" }
        return json5 ? JSONString.unescapeJSON5(base, 0, buffer.count) : JSONString.unescape(base, 0, buffer.count)
    }
}

/// String bodies, as they sit between the quotes, that reach every branch of both decoders.
private let craftedText = [
    #"\"\\\/\b\f\n\r\t"#, #"café 中 😀"#, #"\ud83d"#, #"\ude00x"#, #"\ud83dA"#, #"\u12"#, #"\u"#, #"abc\"#,
    #"\q\x41\v\0\'"#, "a\\\u{2028}b", "a\\\r\nb", #"a very long plain run of text before the escape at its end\n"#
]

/// Bodies only lenient mode admits: ill-formed UTF-8 around escapes, and a JSON5 line continuation.
private let craftedBytes: [[UInt8]] = [
    [0x61, 0x5C, 0x0A, 0x62], [0x61, 0x5C, 0x6E, 0xFF, 0x62], [0xC3, 0x5C, 0x6E], [0xC0, 0x80, 0x5C, 0x74],
    [0xE2, 0x82, 0x5C, 0x6E], [0x5C, 0xE2, 0x82, 0xAC], [0x5C, 0xF0, 0x9F, 0x98], [0xED, 0xA0, 0x80, 0x5C, 0x72]
]

struct StringUnescapeTests {
    @Test func craftedBodiesDecodeAsBefore() {
        for body in craftedText.map({ Array($0.utf8) }) + craftedBytes {
            #expect(unescaped(body, json5: false) == referenceUnescape(body), "\(body)")
            #expect(unescaped(body, json5: true) == referenceUnescapeJSON5(body), "\(body)")
        }
    }

    @Test func randomBodiesDecodeAsBefore() {
        // Bytes biased toward backslashes, escape letters, hex digits, and UTF-8 lead and continuation
        // bytes, so escapes, truncations, and ill-formed sequences all come up.
        let alphabet =
            Array(#"\\\\\\nrtbfu0123456789abcdefABCDEFxv'"/ "#.utf8) + [0x0A, 0x0D, 0x80, 0xA9, 0xC3, 0xE2, 0xF0, 0xFF]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        for _ in 0 ..< 5_000 {
            let body = (0 ..< next() % 40).map { _ in alphabet[next() % alphabet.count] }
            #expect(unescaped(body, json5: false) == referenceUnescape(body), "\(body)")
            #expect(unescaped(body, json5: true) == referenceUnescapeJSON5(body), "\(body)")
        }
    }

    @Test func lenientParsesDecodeEscapedStringsAsBefore() throws {
        let body: [UInt8] = Array(#"lenient \u12\ud800 \q"#.utf8) + [0xFF, 0x5C, 0x6E]
        let document = try AemiJSON.parse([0x22] + body + [0x22], options: .lenient)
        #expect(document.root.string == referenceUnescape(body))
    }
}
