public import AemiJSONCore
internal import Synchronization

/// Where a connection writes its messages: a child process's standard input, a socket, a test's buffer.
public protocol JSONRPCSink: Sendable {
    /// Writes `bytes`, one framed message, whole: concurrent calls must not interleave.
    func write(_ bytes: [UInt8]) async throws
}

/// What a connection tells the peer about a request it stops waiting for, at its deadline or when its caller is cancelled.
public struct JSONRPCCancellation: Sendable {
    public let method: String
    public let params: @Sendable (JSONRPCID) -> JSONValue

    public init(method: String, params: @escaping @Sendable (JSONRPCID) -> JSONValue) {
        self.method = method
        self.params = params
    }

    /// LSP: `$/cancelRequest` with `{"id": …}`.
    public static let languageServer = JSONRPCCancellation(method: "$/cancelRequest") { ["id": $0.jsonValue] }
    /// MCP: `notifications/cancelled` with `{"requestId": …}`.
    public static let modelContextProtocol = JSONRPCCancellation(method: "notifications/cancelled") {
        ["requestId": $0.jsonValue, "reason": "the client stopped waiting"]
    }
}

/// Why a request gave no result.
public enum JSONRPCConnectionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The peer answered with an error.
    case response(JSONRPCError)
    /// No answer within the deadline.
    case timedOut(method: String, after: Duration)
    /// The peer's output ended or broke before the answer.
    case closed(reason: String)

    public var description: String {
        switch self {
            case .response(let error): "the peer answered with \(error)"
            case .timedOut(let method, let after): "the peer did not answer \(method) within \(after)"
            case .closed(let reason): "the connection closed: \(reason)"
        }
    }
}

/// JSON-RPC 2.0 over a byte stream: requests matched to their responses by id, any number in flight.
///
/// Transport-agnostic: messages go out through a ``JSONRPCSink`` and the peer's bytes come in through ``run(reading:)``. Every request
/// has a deadline. A request given up on, at its deadline or because its caller was cancelled, is forgotten, its late answer is dropped,
/// and the peer is told when a ``JSONRPCCancellation`` is set. Requests from the peer are answered by `onRequest`, each in its own child
/// task so the reader never waits on one, or with a null result when there is no handler, so the peer never waits on this side.
/// Notifications go to `onNotification` in order, on the reader: the handler must not wait on a response from this connection.
public final class JSONRPCConnection: Sendable {
    public typealias RequestHandler = @Sendable (JSONRPCRequest) async -> Result<JSONValue, JSONRPCError>
    public typealias NotificationHandler = @Sendable (JSONRPCNotification) async -> Void

    private enum Slot {
        /// Sent; nobody waits yet.
        case pending
        case waiting(CheckedContinuation<JSON, any Error>)
        case answered(Result<JSON, JSONRPCConnectionError>)
    }

    private struct State {
        var nextID: Int64 = 1
        var slots: [Int64: Slot] = [:]
        /// Set once the peer's output ends: every later request fails at once.
        var closed: JSONRPCConnectionError?
        var closeWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var nextWaiter = 0
    }

    private let sink: any JSONRPCSink
    private let framing: JSONRPCFraming
    private let cancellation: JSONRPCCancellation?
    private let onRequest: RequestHandler?
    private let onNotification: NotificationHandler?
    private let state = Mutex(State())

    public init(
        sink: any JSONRPCSink, framing: JSONRPCFraming, cancellation: JSONRPCCancellation? = nil,
        onRequest: RequestHandler? = nil, onNotification: NotificationHandler? = nil
    ) {
        self.sink = sink
        self.framing = framing
        self.cancellation = cancellation
        self.onRequest = onRequest
        self.onNotification = onNotification
    }

    // MARK: Sending

    /// Sends `method` with `params` and returns the response's `result`.
    ///
    /// - Throws: ``JSONRPCConnectionError`` for an error response, a closed connection or the deadline; the sink's error;
    ///   `CancellationError` when the caller is cancelled; an encoding error when `params` holds a number JSON cannot spell.
    public func request(_ method: String, _ params: JSONValue? = nil, timeout: Duration = .seconds(120)) async throws
        -> JSON
    {
        let id = try state.withLock { state throws(JSONRPCConnectionError) -> Int64 in
            if let closed = state.closed { throw closed }
            let id = state.nextID
            state.nextID += 1
            state.slots[id] = .pending
            return id
        }
        do {
            try await sink.write(framing.frame(JSONRPC.request(id: .number(id), method: method, params: params)))
            return try await withThrowingTaskGroup(of: JSON.self) { group in
                group.addTask { try await self.answer(id) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw JSONRPCConnectionError.timedOut(method: method, after: timeout)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        } catch {
            abandon(id)
            if error is CancellationError || Self.isTimeout(error) {
                await tellPeer(abandoned: id)
            }
            throw error
        }
    }

    /// Sends a notification: no id, no answer.
    public func notify(_ method: String, _ params: JSONValue? = nil) async throws {
        try await sink.write(framing.frame(JSONRPC.notification(method: method, params: params)))
    }

    private static func isTimeout(_ error: any Error) -> Bool {
        if case .timedOut = error as? JSONRPCConnectionError { return true }
        return false
    }

    /// Tells the peer that request `id` is no longer awaited, when the connection knows how and is still open.
    private func tellPeer(abandoned id: Int64) async {
        guard let cancellation, state.withLock({ $0.closed == nil }) else { return }
        let params = cancellation.params(.number(id))
        guard let body = try? JSONRPC.notification(method: cancellation.method, params: params) else { return }
        try? await sink.write(framing.frame(body))
    }

    /// Waits for the answer to `id`, or for cancellation.
    private func answer(_ id: Int64) async throws -> JSON {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSON, any Error>) in
                enum Next {
                    case wait
                    case deliver(Result<JSON, JSONRPCConnectionError>)
                    case abandoned
                }
                let next = state.withLock { state -> Next in
                    switch state.slots[id] {
                        case .pending:
                            state.slots[id] = .waiting(continuation)
                            return .wait
                        case .answered(let result):
                            state.slots[id] = nil
                            return .deliver(result)
                        case .waiting, nil:
                            return .abandoned
                    }
                }
                switch next {
                    case .wait: break
                    case .deliver(let result): continuation.resume(with: result)
                    case .abandoned: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            abandon(id)
        }
    }

    /// Forgets `id`; a waiter is resumed with `CancellationError`.
    private func abandon(_ id: Int64) {
        let waiter = state.withLock { state -> CheckedContinuation<JSON, any Error>? in
            defer { state.slots[id] = nil }
            if case .waiting(let continuation) = state.slots[id] { return continuation }
            return nil
        }
        waiter?.resume(throwing: CancellationError())
    }

    // MARK: Receiving

    /// Reads the peer's output until it ends, delivering each message, then waits for the peer's requests in progress to be answered.
    ///
    /// When the output ends or is not framed, every request in flight fails with ``JSONRPCConnectionError/closed(reason:)``, and so does
    /// every later one. A body that is not a message, and a line too long to read, are dropped.
    public func run(reading chunks: some AsyncSequence<[UInt8], any Error>) async {
        await withTaskGroup(of: Void.self) { group in
            var reason = "the peer's output ended"
            do {
                switch framing {
                    case .contentLength:
                        var decoder = ContentLengthFraming()
                        for try await chunk in chunks {
                            for body in try decoder.append(chunk) { await receive(body, &group) }
                        }
                    case .lines:
                        var decoder = LineFraming()
                        for try await chunk in chunks {
                            for case .message(let body) in decoder.append(chunk) { await receive(body, &group) }
                        }
                }
            } catch {
                reason = String(describing: error)
            }
            close(reason: reason)
        }
    }

    /// Delivers one message.
    private func receive(_ body: [UInt8], _ group: inout TaskGroup<Void>) async {
        guard let message = try? JSONRPCMessage(parsing: body) else { return }
        switch message {
            case .request(let request):
                group.addTask { await self.answer(request) }
            case .notification(let notification):
                await onNotification?(notification)
            case .response(let id, let result):
                guard case .number(let number) = id else { return }
                deliver(number, result.mapError(JSONRPCConnectionError.response))
        }
    }

    /// Answers a request from the peer.
    private func answer(_ request: JSONRPCRequest) async {
        let outcome = await onRequest?(request) ?? .success(.null)
        let body: [UInt8]?
        switch outcome {
            case .success(let result): body = try? JSONRPC.response(id: request.id, result: result)
            case .failure(let error): body = try? JSONRPC.response(id: request.id, error: error)
        }
        let internalError = JSONRPCError(code: JSONRPCError.internalError, message: "the result could not be written")
        guard let bytes = try? body ?? JSONRPC.response(id: request.id, error: internalError) else { return }
        try? await sink.write(framing.frame(bytes))
    }

    private func deliver(_ id: Int64, _ result: Result<JSON, JSONRPCConnectionError>) {
        let waiter = state.withLock { state -> CheckedContinuation<JSON, any Error>? in
            switch state.slots[id] {
                case .pending:
                    state.slots[id] = .answered(result)
                    return nil
                case .waiting(let continuation):
                    state.slots[id] = nil
                    return continuation
                case .answered, nil:
                    return nil
            }
        }
        waiter?.resume(with: result)
    }

    /// Returns once the peer's output has ended, or the caller is cancelled.
    public func waitUntilClosed() async {
        let key = state.withLock { state -> Int in
            state.nextWaiter += 1
            return state.nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.closed != nil || Task.isCancelled { return true }
                    state.closeWaiters[key] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.closeWaiters.removeValue(forKey: key) }?.resume()
        }
    }

    private func close(reason: String) {
        let error = JSONRPCConnectionError.closed(reason: reason)
        let (waiters, closeWaiters) = state.withLock {
            state -> ([CheckedContinuation<JSON, any Error>], [CheckedContinuation<Void, Never>]) in
            state.closed = error
            let closeWaiters = Array(state.closeWaiters.values)
            state.closeWaiters = [:]
            var waiters: [CheckedContinuation<JSON, any Error>] = []
            for (id, slot) in state.slots {
                switch slot {
                    case .waiting(let continuation):
                        waiters.append(continuation)
                        state.slots[id] = nil
                    case .pending:
                        state.slots[id] = .answered(.failure(error))
                    case .answered:
                        break
                }
            }
            return (waiters, closeWaiters)
        }
        for waiter in waiters { waiter.resume(throwing: error) }
        for waiter in closeWaiters { waiter.resume() }
    }
}
