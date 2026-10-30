import Testing

@testable import AemiJSONRPC

@Suite struct ContentLengthFramingTests {
    private let messages: [[UInt8]] = [Array(#"{"id":1}"#.utf8), Array(#"{"id":2,"result":"é"}"#.utf8)]

    private func stream() -> [UInt8] { messages.flatMap(ContentLengthFraming.frame) }

    @Test func framesABodyWithItsLength() {
        let framed = ContentLengthFraming.frame(Array("{}".utf8))
        #expect(framed == Array("Content-Length: 2\r\n\r\n{}".utf8))
    }

    @Test func decodesTwoMessagesCutAtEveryOffset() throws {
        let bytes = stream()
        for cut in 0 ... bytes.count {
            var framing = ContentLengthFraming()
            var bodies = try framing.append(bytes[0 ..< cut])
            bodies += try framing.append(bytes[cut...])
            #expect(bodies == messages, "cut at \(cut)")
        }
    }

    @Test func decodesTwoMessagesOneByteAtATime() throws {
        var framing = ContentLengthFraming()
        var bodies: [[UInt8]] = []
        for byte in stream() { bodies += try framing.append(CollectionOfOne(byte)) }
        #expect(bodies == messages)
    }

    @Test func readsTheLengthFromAnyHeaderLineInAnyCase() throws {
        var framing = ContentLengthFraming()
        let framed = Array("Content-Type: application/vscode-jsonrpc\r\ncontent-LENGTH:2\r\n\r\n{}".utf8)
        #expect(try framing.append(framed) == [Array("{}".utf8)])
    }

    @Test func acceptsAnEmptyBody() throws {
        var framing = ContentLengthFraming()
        #expect(try framing.append(Array("Content-Length: 0\r\n\r\n".utf8)) == [[]])
    }

    @Test(arguments: [
        ("Content-Length: x\r\n\r\n", JSONRPCFramingError.missingContentLength),
        ("Content-Type: a\r\n\r\n", .missingContentLength),
        ("Content-Length: -1\r\n\r\n", .missingContentLength),
        ("Content-Length: \r\n\r\n", .missingContentLength),
        ("Content-Length: 99999999999\r\n\r\n", .contentTooLong(99_999_999_999)),
        ("Content-Length: 999999999999999999999999\r\n\r\n", .missingContentLength)
    ])
    func refusesAHeaderItCannotTrust(header: String, failure: JSONRPCFramingError) {
        var framing = ContentLengthFraming()
        #expect(throws: failure) { try framing.append(Array(header.utf8)) }
    }

    @Test func refusesAHeaderThatNeverEnds() {
        var framing = ContentLengthFraming()
        let endless = [UInt8](repeating: UInt8(ascii: "a"), count: ContentLengthFraming.defaultMaximumHeaderLength + 1)
        #expect(throws: JSONRPCFramingError.headerTooLong) { try framing.append(endless) }
    }

    @Test func refusesALongHeaderThatEnds() {
        var framing = ContentLengthFraming(maximumHeaderLength: 32)
        let header = "X-Padding: " + String(repeating: "a", count: 40) + "\r\nContent-Length: 2\r\n\r\n{}"
        #expect(throws: JSONRPCFramingError.headerTooLong) { try framing.append(Array(header.utf8)) }
    }

    @Test func honoursItsBodyLimit() {
        var framing = ContentLengthFraming(maximumContentLength: 4)
        #expect(throws: JSONRPCFramingError.contentTooLong(5)) {
            try framing.append(Array("Content-Length: 5\r\n\r\n".utf8))
        }
    }

    /// A body arriving in many chunks is not scanned again with each one.
    @Test func scansEachByteOnce() throws {
        let body = [UInt8](repeating: UInt8(ascii: " "), count: 1 << 20)
        let bytes = ContentLengthFraming.frame(body)
        var framing = ContentLengthFraming()
        var bodies: [[UInt8]] = []
        var offset = 0
        while offset < bytes.count {
            bodies += try framing.append(bytes[offset ..< min(offset + 1000, bytes.count)])
            offset += 1000
        }
        #expect(bodies == [body])
        #expect(framing.bytesScanned <= 64)
    }
}

@Suite struct LineFramingTests {
    @Test func framesABodyAsALine() {
        #expect(LineFraming.frame(Array("{}".utf8)) == Array("{}\n".utf8))
    }

    @Test func splitsOnLFAndCRLFAndSkipsBlankLines() {
        var framing = LineFraming()
        let lines = framing.append(Array("{\"a\":1}\r\n\n  \r\n{\"b\":2}\n{\"c\"".utf8))
        #expect(lines == [.message(Array(#"{"a":1}"#.utf8)), .message(Array(#"{"b":2}"#.utf8))])
        #expect(framing.append(Array(":3}\n".utf8)) == [.message(Array(#"{"c":3}"#.utf8))])
    }

    @Test func decodesTwoLinesCutAtEveryOffset() {
        let bytes = Array("{\"id\":1}\r\n{\"id\":2,\"r\":\"é\"}\n".utf8)
        let expected: [LineFraming.Line] = [
            .message(Array(#"{"id":1}"#.utf8)), .message(Array(#"{"id":2,"r":"é"}"#.utf8))
        ]
        for cut in 0 ... bytes.count {
            var framing = LineFraming()
            var lines = framing.append(bytes[0 ..< cut])
            lines += framing.append(bytes[cut...])
            #expect(lines == expected, "cut at \(cut)")
        }
    }

    @Test func reportsAnOverlongLineOnceAndGoesOn() {
        var framing = LineFraming(maximumLineLength: 8)
        var lines = framing.append(Array("0123456789".utf8))
        lines += framing.append(Array("abcdef\n{}\n".utf8))
        #expect(lines == [.tooLong, .message(Array("{}".utf8))])
    }

    @Test func reportsAnOverlongLineThatArrivesWhole() {
        var framing = LineFraming(maximumLineLength: 4)
        #expect(framing.append(Array("123456\n{}\n".utf8)) == [.tooLong, .message(Array("{}".utf8))])
    }

    /// A line arriving in many chunks is not scanned again with each one.
    @Test func scansEachByteOnce() {
        var bytes = [UInt8](repeating: UInt8(ascii: "a"), count: 1 << 20)
        bytes.append(UInt8(ascii: "\n"))
        var framing = LineFraming()
        var lines: [LineFraming.Line] = []
        var offset = 0
        while offset < bytes.count {
            lines += framing.append(bytes[offset ..< min(offset + 1000, bytes.count)])
            offset += 1000
        }
        #expect(lines.count == 1)
        #expect(framing.bytesScanned == bytes.count)
    }
}
