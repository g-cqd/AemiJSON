import AemiJSONCore
import AemiJSONRPC
import Synchronization
import Testing

/// What a serving connection wrote, as the client reads it: one message a line.
private final class Written: JSONRPCSink {
    private let bytes = Mutex<[UInt8]>([])

    func write(_ bytes: [UInt8]) async throws { self.bytes.withLock { $0 += bytes } }

    /// The responses written, in order: each id, and its result or error.
    var responses: [(id: JSONRPCID?, outcome: Result<JSON, JSONRPCError>)] {
        var framing = LineFraming()
        return framing.append(bytes.withLock { $0 })
            .compactMap { line in
                guard case .message(let body) = line,
                    case .response(let id, let outcome)? = try? JSONRPCMessage(parsing: body)
                else { return nil }
                return (id, outcome)
            }
    }
}

/// The client's lines as a stream that has already ended: `run` returns once each was read and every admitted request answered.
private func lines(_ lines: [String]) -> AsyncThrowingStream<[UInt8], any Error> {
    let (stream, feed) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
    feed.yield(lines.flatMap { Array($0.utf8) + [UInt8(ascii: "\n")] })
    feed.finish()
    return stream
}

private func request(_ id: Int, _ method: String) -> String { #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"# }

/// A connection in the server's role: the order requests arrive in is the order they are admitted in, whatever the order their
/// answers are ready in, and a body that is not a message is answered with its error.
@Suite(.timeLimit(.minutes(1))) struct JSONRPCServingConnectionTests {
    @Test func admitsRequestsInTheOrderTheyArrive() async throws {
        let admitted = Mutex<[String]>([])
        let written = Written()
        let connection = JSONRPCConnection(serving: written, framing: .lines) { request in
            admitted.withLock { $0.append(request.method) }
            return { .success(.string(request.method)) }
        }
        let methods = (0 ..< 200).map { "m\($0)" }
        await connection.run(reading: lines(methods.enumerated().map { request($0.offset, $0.element) }))
        #expect(admitted.withLock { $0 } == methods)
        #expect(written.responses.count == methods.count)
    }

    @Test func whatAnAdmissionChangesIsSeenByTheNextOne() async throws {
        // The case this is for: a server that answers nothing before `open`, asked `open` and something else in one write.
        let open = Mutex(false)
        let written = Written()
        let connection = JSONRPCConnection(serving: written, framing: .lines) { request in
            if request.method == "open" {
                open.withLock { $0 = true }
                return { .success(true) }
            }
            let wasOpen = open.withLock { $0 }
            return {
                wasOpen ? .success(true) : .failure(JSONRPCError(code: JSONRPCError.invalidRequest, message: "closed"))
            }
        }
        await connection.run(
            reading: lines([request(1, "early"), request(2, "open")] + (3 ... 50).map { request($0, "late") })
        )
        let outcomes = Dictionary(
            uniqueKeysWithValues: written.responses.compactMap { answer in answer.id.map { ($0, answer.outcome) } }
        )
        #expect(throws: JSONRPCError(code: JSONRPCError.invalidRequest, message: "closed")) {
            try outcomes[.number(1)]?.get()
        }
        for id in 2 ... 50 { #expect(try outcomes[.number(Int64(id))]?.get().bool == true, "request \(id)") }
    }

    @Test func workThatWaitsDoesNotHoldTheReader() async throws {
        // The first request's work ends only when the second has been admitted: with the reader held, neither would be answered.
        let (released, release) = AsyncStream<Void>.makeStream()
        let written = Written()
        let connection = JSONRPCConnection(serving: written, framing: .lines) { request in
            if request.method == "release" {
                release.finish()
                return { .success("released") }
            }
            return {
                for await _ in released {}
                return .success("waited")
            }
        }
        await connection.run(reading: lines([request(1, "wait"), request(2, "release")]))
        let outcomes = Dictionary(
            uniqueKeysWithValues: written.responses.compactMap { answer in answer.id.map { ($0, answer.outcome) } }
        )
        #expect(try outcomes[.number(1)]?.get().string == "waited")
        #expect(try outcomes[.number(2)]?.get().string == "released")
    }

    @Test func answersABodyThatIsNotAMessageWithItsError() async throws {
        let written = Written()
        let connection = JSONRPCConnection(serving: written, framing: .lines) { _ in { .success(true) } }
        await connection.run(
            reading: lines([
                "this is not JSON", #"{"jsonrpc":"1.0","id":3,"method":"x"}"#, #"[1,2]"#, request(4, "fine")
            ])
        )
        let responses = written.responses
        #expect(responses.count == 4)
        #expect(
            responses.map(\.id) == [nil, .number(3), nil, .number(4)],
            "the refusals are written as they are read, in order"
        )
        let codes = responses.map { answer -> Int in
            if case .failure(let error) = answer.outcome { return error.code }
            return 0
        }
        #expect(codes == [JSONRPCError.parseError, JSONRPCError.invalidRequest, JSONRPCError.invalidRequest, 0])
    }

    @Test func answersALineLongerThanTheLimitWithAParseErrorAndReadsOn() async throws {
        let written = Written()
        let connection = JSONRPCConnection(serving: written, framing: .lines) { _ in { .success(true) } }
        let long = String(repeating: "x", count: LineFraming.defaultMaximumLineLength + 1)
        await connection.run(reading: lines([long, request(1, "after")]))
        let responses = written.responses
        #expect(responses.map(\.id) == [nil, .number(1)])
        guard case .failure(let error)? = responses.first?.outcome else {
            Issue.record("the long line was not answered with an error")
            return
        }
        #expect(error.code == JSONRPCError.parseError)
        #expect(error.message == "parse error: a line is longer than \(LineFraming.defaultMaximumLineLength) bytes")
    }

    @Test func answersAnInvalidBodyOverContentLengthFramingToo() async throws {
        let written = Mutex<[UInt8]>([])
        struct Sink: JSONRPCSink {
            let into: @Sendable ([UInt8]) -> Void
            func write(_ bytes: [UInt8]) async throws { into(bytes) }
        }
        let connection = JSONRPCConnection(
            serving: Sink { bytes in written.withLock { $0 += bytes } },
            framing: .contentLength
        ) {
            _ in { .success(true) }
        }
        let (stream, feed) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
        feed.yield(ContentLengthFraming.frame(Array("{nope".utf8)))
        feed.finish()
        await connection.run(reading: stream)
        var decoder = ContentLengthFraming()
        let bodies = try decoder.append(written.withLock { $0 })
        #expect(bodies.count == 1)
        guard case .response(let id, .failure(let error))? = try bodies.first.map({ try JSONRPCMessage(parsing: $0) })
        else {
            Issue.record("not an error response")
            return
        }
        #expect(id == nil && error.code == JSONRPCError.parseError)
    }

    @Test func aConnectionThatDoesNotServeSaysNothingOfWhatItCannotRead() async throws {
        // A client reads a server's output, which may hold lines that are not messages (a log line): answering them would be noise.
        let written = Written()
        let connection = JSONRPCConnection(sink: written, framing: .lines)
        await connection.run(reading: lines(["this is not JSON", #"{"jsonrpc":"1.0","id":3,"method":"x"}"#]))
        #expect(written.responses.isEmpty)
    }
}
