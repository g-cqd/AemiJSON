import AemiJSONCore
import AemiJSONRPC
import Synchronization
import Testing

/// A peer in the test: it sees each message the connection writes and answers through `output`.
private final class ScriptedPeer: JSONRPCSink {
    typealias Script = @Sendable (_ message: JSONRPCMessage, _ peer: ScriptedPeer) -> Void

    let framing: JSONRPCFraming
    let output: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let script: Script
    let written = Mutex<[JSONRPCMessage]>([])

    init(framing: JSONRPCFraming = .contentLength, _ script: @escaping Script) {
        self.framing = framing
        (output, continuation) = AsyncThrowingStream.makeStream()
        self.script = script
    }

    func write(_ bytes: [UInt8]) async throws {
        for body in try bodies(bytes) {
            let message = try JSONRPCMessage(parsing: body)
            written.withLock { $0.append(message) }
            script(message, self)
        }
    }

    private func bodies(_ bytes: [UInt8]) throws -> [[UInt8]] {
        switch framing {
            case .contentLength:
                var decoder = ContentLengthFraming()
                return try decoder.append(bytes)
            case .lines:
                var decoder = LineFraming()
                return decoder.append(bytes)
                    .compactMap { line in
                        if case .message(let body) = line { return body }
                        return nil
                    }
        }
    }

    func send(_ text: String) {
        let body = Array(text.utf8)
        switch framing {
            case .contentLength: continuation.yield(ContentLengthFraming.frame(body))
            case .lines: continuation.yield(LineFraming.frame(body))
        }
    }

    func reply(to message: JSONRPCMessage, result: String) {
        guard case .request(let request) = message, case .number(let id) = request.id else { return }
        send(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#)
    }

    func end() { continuation.finish() }

    func sent(_ method: String) -> [JSONRPCNotification] {
        written.withLock { messages in
            messages.compactMap { message in
                guard case .notification(let note) = message, note.method == method else { return nil }
                return note
            }
        }
    }

    func answers() -> [(JSONRPCID?, Result<JSON, JSONRPCError>)] {
        written.withLock { messages in
            messages.compactMap { message in
                guard case .response(let id, let result) = message else { return nil }
                return (id, result)
            }
        }
    }
}

private func requestID(_ message: JSONRPCMessage) -> Int64? {
    guard case .request(let request) = message, case .number(let id) = request.id else { return nil }
    return id
}

@Suite struct JSONRPCConnectionTests {
    @Test func matchesResponsesToRequestsByIDInAnyOrder() async throws {
        let held = Mutex<[JSONRPCMessage]>([])
        let peer = ScriptedPeer { message, peer in
            let both = held.withLock { held -> [JSONRPCMessage] in
                held.append(message)
                return held.count == 2 ? held : []
            }
            for message in both.reversed() { peer.reply(to: message, result: "\(requestID(message) ?? 0)") }
        }
        let connection = JSONRPCConnection(sink: peer, framing: .contentLength)
        let reader = Task { await connection.run(reading: peer.output) }
        async let first = connection.request("a")
        async let second = connection.request("b")
        let results = try await [first.intValue, second.intValue]
        #expect(results.sorted() == [1, 2])
        peer.end()
        await reader.value
    }

    @Test func worksOverLines() async throws {
        let peer = ScriptedPeer(framing: .lines) { message, peer in peer.reply(to: message, result: #""ok""#) }
        let connection = JSONRPCConnection(sink: peer, framing: .lines)
        let reader = Task { await connection.run(reading: peer.output) }
        let result = try await connection.request("a", ["x": 1])
        #expect(result.string == "ok")
        peer.end()
        await reader.value
    }

    @Test func throwsThePeersError() async throws {
        let peer = ScriptedPeer { message, peer in
            peer.send(#"{"jsonrpc":"2.0","id":\#(requestID(message) ?? 0),"error":{"code":-32601,"message":"no"}}"#)
        }
        let connection = JSONRPCConnection(sink: peer, framing: .contentLength)
        let reader = Task { await connection.run(reading: peer.output) }
        let expected = JSONRPCConnectionError.response(JSONRPCError(code: JSONRPCError.methodNotFound, message: "no"))
        await #expect(throws: expected) { try await connection.request("missing") }
        peer.end()
        await reader.value
    }

    @Test func ignoresAResponseForAnUnknownID() async throws {
        let peer = ScriptedPeer { message, peer in
            peer.send(#"{"jsonrpc":"2.0","id":999,"result":0}"#)
            peer.send(#"{"jsonrpc":"2.0","id":"x","result":0}"#)
            peer.send("not json")
            peer.reply(to: message, result: "5")
        }
        let connection = JSONRPCConnection(sink: peer, framing: .contentLength)
        let reader = Task { await connection.run(reading: peer.output) }
        #expect(try await connection.request("a").int == 5)
        peer.end()
        await reader.value
    }

    @Test func answersThePeersRequestsWithNullByDefault() async throws {
        let peer = ScriptedPeer { message, peer in
            guard requestID(message) != nil else { return }
            peer.send(#"{"jsonrpc":"2.0","id":"sk-1","method":"window/workDoneProgress/create","params":{}}"#)
            peer.reply(to: message, result: "true")
        }
        let connection = JSONRPCConnection(sink: peer, framing: .contentLength)
        let reader = Task { await connection.run(reading: peer.output) }
        _ = try await connection.request("a")
        peer.end()
        await reader.value
        let answers = peer.answers()
        #expect(answers.count == 1)
        #expect(answers.first?.0 == .string("sk-1"))
        #expect(try answers.first?.1.get().isNull == true)
    }

    @Test func answersThePeersRequestsWithTheHandler() async throws {
        let peer = ScriptedPeer { message, peer in
            guard requestID(message) != nil else { return }
            peer.send(#"{"jsonrpc":"2.0","id":"p1","method":"echo","params":{"v":3}}"#)
            peer.send(#"{"jsonrpc":"2.0","id":"p2","method":"nope"}"#)
            peer.reply(to: message, result: "true")
        }
        let connection = JSONRPCConnection(
            sink: peer, framing: .contentLength,
            onRequest: { request in
                guard request.method == "echo", let params = request.params else {
                    return .failure(JSONRPCError(code: JSONRPCError.methodNotFound, message: request.method))
                }
                return .success(JSONValue(params["v"]))
            })
        let reader = Task { await connection.run(reading: peer.output) }
        _ = try await connection.request("a")
        peer.end()
        await reader.value
        let answers = Dictionary(
            uniqueKeysWithValues: peer.answers().compactMap { id, result in id.map { ($0, result) } })
        #expect(try answers[.string("p1")]?.get().int == 3)
        #expect(throws: JSONRPCError(code: JSONRPCError.methodNotFound, message: "nope")) {
            try answers[.string("p2")]?.get()
        }
    }

    @Test func deliversNotificationsInOrder() async throws {
        let peer = ScriptedPeer { message, peer in
            for n in 0 ..< 5 { peer.send(#"{"jsonrpc":"2.0","method":"progress","params":{"n":\#(n)}}"#) }
            peer.reply(to: message, result: "0")
        }
        let seen = Mutex<[Int]>([])
        let connection = JSONRPCConnection(
            sink: peer, framing: .contentLength,
            onNotification: { note in seen.withLock { $0.append(note.params?["n"].int ?? -1) } })
        let reader = Task { await connection.run(reading: peer.output) }
        _ = try await connection.request("a")
        peer.end()
        await reader.value
        #expect(seen.withLock { $0 } == [0, 1, 2, 3, 4])
    }

    @Test func failsRequestsInFlightAndLaterOnesWhenTheOutputEnds() async throws {
        let peer = ScriptedPeer { _, peer in peer.end() }
        let connection = JSONRPCConnection(sink: peer, framing: .contentLength)
        let reader = Task { await connection.run(reading: peer.output) }
        let closed = JSONRPCConnectionError.closed(reason: "the peer's output ended")
        await #expect(throws: closed) { try await connection.request("a") }
        await reader.value
        await #expect(throws: closed) { try await connection.request("b") }
        await connection.waitUntilClosed()
    }

    @Test func closesOnABrokenFrame() async throws {
        let peer = ScriptedPeer { _, peer in peer.send("") }
        let connection = JSONRPCConnection(sink: peer, framing: .contentLength)
        let reader = Task {
            await connection.run(reading: AsyncThrowingStream { $0.yield(Array("Content-Length: x\r\n\r\n".utf8)) })
        }
        await reader.value
        let closed = JSONRPCConnectionError.closed(reason: String(describing: JSONRPCFramingError.missingContentLength))
        await #expect(throws: closed) { try await connection.request("a") }
        peer.end()
    }

    @Test func givesUpAtTheDeadlineAndTellsTheLanguageServer() async throws {
        let peer = ScriptedPeer { _, _ in }
        let connection = JSONRPCConnection(sink: peer, framing: .contentLength, cancellation: .languageServer)
        let reader = Task { await connection.run(reading: peer.output) }
        await #expect(throws: JSONRPCConnectionError.timedOut(method: "slow", after: .milliseconds(50))) {
            try await connection.request("slow", timeout: .milliseconds(50))
        }
        let cancels = peer.sent("$/cancelRequest")
        #expect(cancels.count == 1)
        #expect(cancels.first?.params?["id"].int == 1)
        peer.end()
        await reader.value
    }

    @Test func aCancelledCallerTellsTheMCPServer() async throws {
        let received = AsyncStream.makeStream(of: Void.self)
        let peer = ScriptedPeer { _, _ in received.continuation.yield() }
        let connection = JSONRPCConnection(sink: peer, framing: .lines, cancellation: .modelContextProtocol)
        let reader = Task { await connection.run(reading: peer.output) }
        let caller = Task { try await connection.request("slow") }
        for await _ in received.stream { break }
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        let cancels = peer.sent("notifications/cancelled")
        #expect(cancels.count == 1)
        #expect(cancels.first?.params?["requestId"].int == 1)
        peer.end()
        await reader.value
    }

    @Test func dropsALateAnswer() async throws {
        let late = Mutex<JSONRPCMessage?>(nil)
        let peer = ScriptedPeer { message, peer in
            guard let id = requestID(message) else { return }
            if id == 1 {
                late.withLock { $0 = message }
            } else {
                if let first = late.withLock({ $0 }) { peer.reply(to: first, result: "1") }
                peer.reply(to: message, result: "2")
            }
        }
        let connection = JSONRPCConnection(sink: peer, framing: .contentLength)
        let reader = Task { await connection.run(reading: peer.output) }
        await #expect(throws: JSONRPCConnectionError.timedOut(method: "a", after: .milliseconds(20))) {
            try await connection.request("a", timeout: .milliseconds(20))
        }
        #expect(try await connection.request("b").int == 2)
        peer.end()
        await reader.value
    }

    @Test func notifiesWithoutAnID() async throws {
        let peer = ScriptedPeer { _, _ in }
        let connection = JSONRPCConnection(sink: peer, framing: .lines)
        try await connection.notify("initialized", [:])
        #expect(peer.sent("initialized").count == 1)
    }
}
