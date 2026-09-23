import AemiJSONCore
public import AemiRuntime

#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

extension JSONDocument {
    /// Tape indices of each top-level array element (single pass), or nil if the
    /// root isn't an array.
    func topLevelArrayElementStarts() -> [Int]? {
        guard !tape.isEmpty, Slot.tag(tape[0]) == JSONKind.array.rawValue else { return nil }
        let count = Slot.count(tape[0])
        var out: [Int] = []
        out.reserveCapacity(count)
        var i = 1
        for _ in 0 ..< count {
            out.append(i)
            let s = tape[i]
            let t = Slot.tag(s)
            i = (t == JSONKind.object.rawValue || t == JSONKind.array.rawValue) ? Slot.low(s) : i + 1
        }
        return out
    }

    /// Decode a contiguous range of array elements. Each call binds its own base
    /// pointer over the shared immutable storage, so it is safe to run from many
    /// tasks at once. Checks for cancellation of the current task every 256 elements, starting
    /// with the first, and throws `CancellationError` once it is cancelled.
    func decodeElementRange<T: Decodable>(
        _ type: T.Type, _ lo: Int, _ hi: Int, _ starts: [Int], maxDecodingDepth: Int
    ) throws -> [T] {
        try withDecodeContext(
            userInfo: [:], strategies: DecodeStrategies(), maxDecodeDepth: maxDecodingDepth
        ) { ctx in
            var out: [T] = []
            out.reserveCapacity(hi - lo)
            for k in lo ..< hi {
                if (k - lo) & 255 == 0 { try Task.checkCancellation() }
                out.append(try ctx.decodeValue(T.self, at: starts[k]))
            }
            return out
        }
    }
}

extension AemiJSON {
    /// Default per-element native-recursion cap for the concurrent path: the same default as
    /// ``AemiJSON/JSONDecoder/maxDecodingDepth`` (64), since the element decoders run on the
    /// cooperative pool's 512 KiB stacks. Past it an over-nested element throws a catchable
    /// `DecodingError` instead of crashing the pool thread; raise it via the `maxDecodingDepth`
    /// parameter when elements are legitimately deeper.
    public static let concurrentDecodeDefaultDepth = JSONDecoder.defaultMaxDecodingDepth

    /// Decode a top-level JSON array, scanning once on the calling task then
    /// decoding element batches in parallel across cores. Off the main actor.
    /// Static (no decoder instance) so nothing non-Sendable crosses isolation.
    ///
    /// The batches run as child tasks of a task group, so the call returns only once every batch has
    /// stopped. Cancelling the calling task cancels them, and each stops within 256 elements with a
    /// `CancellationError`; the first element that fails to decode cancels the rest the same way.
    ///
    /// - Important: This path uses the **default** decoding configuration — `.useDefaultKeys`,
    ///   `.deferredToDate`, `.base64`, and an empty `userInfo`. It deliberately takes no
    ///   ``AemiJSON/JSONDecoder`` instance so nothing non-`Sendable` (e.g. a `.custom` strategy
    ///   closure or arbitrary `userInfo`) crosses the task boundary. If you need snake_case keys, a
    ///   date strategy, or `userInfo`, decode serially with a configured ``AemiJSON/JSONDecoder``, or
    ///   pre-transform the element types so the default mapping suffices.
    public static func decodeArrayConcurrently<T: Decodable & Sendable>(
        _ type: T.Type, from data: Data, minimumBatch: Int = 512,
        maxDecodingDepth: Int = concurrentDecodeDefaultDepth
    ) async throws -> [T] {
        try await decodeArrayConcurrently(
            type, from: try AemiJSON.parse(data), minimumBatch: minimumBatch, maxDecodingDepth: maxDecodingDepth)
    }

    public static func decodeArrayConcurrently<T: Decodable & Sendable>(
        _ type: T.Type, from document: JSONDocument, minimumBatch: Int = 512,
        maxDecodingDepth: Int = concurrentDecodeDefaultDepth
    ) async throws -> [T] {
        guard let starts = document.topLevelArrayElementStarts() else {
            return try JSONDecoder().decode([T].self, from: document)
        }
        let n = starts.count
        if n <= minimumBatch {
            return try document.decodeElementRange(T.self, 0, n, starts, maxDecodingDepth: maxDecodingDepth)
        }
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunkCount = min(cores, max(1, n / minimumBatch))
        let chunkSize = (n + chunkCount - 1) / chunkCount

        // One child task per element batch. Each reports its batch number, so the batches are
        // reassembled in input order whatever order they finish in.
        return try await withThrowingTaskGroup(of: (batch: Int, elements: [T]).self) { group in
            var batches = 0
            for lo in stride(from: 0, to: n, by: chunkSize) {
                let batch = batches
                group.addTask {
                    let hi = min(lo + chunkSize, n)
                    return (
                        batch,
                        try document.decodeElementRange(T.self, lo, hi, starts, maxDecodingDepth: maxDecodingDepth)
                    )
                }
                batches += 1
            }
            var parts = [[T]](repeating: [], count: batches)
            for try await part in group { parts[part.batch] = part.elements }
            var out: [T] = []
            out.reserveCapacity(n)
            for part in parts { out.append(contentsOf: part) }
            return out
        }
    }

    @available(*, deprecated, message: "The batches run in a task group; the task provider is no longer used")
    public static func decodeArrayConcurrently<T: Decodable & Sendable>(
        _ type: T.Type, from data: Data, minimumBatch: Int = 512,
        maxDecodingDepth: Int = concurrentDecodeDefaultDepth, taskProvider: any TaskProvider
    ) async throws -> [T] {
        try await decodeArrayConcurrently(
            type, from: data, minimumBatch: minimumBatch, maxDecodingDepth: maxDecodingDepth)
    }

    @available(*, deprecated, message: "The batches run in a task group; the task provider is no longer used")
    public static func decodeArrayConcurrently<T: Decodable & Sendable>(
        _ type: T.Type, from document: JSONDocument, minimumBatch: Int = 512,
        maxDecodingDepth: Int = concurrentDecodeDefaultDepth, taskProvider: any TaskProvider
    ) async throws -> [T] {
        try await decodeArrayConcurrently(
            type, from: document, minimumBatch: minimumBatch, maxDecodingDepth: maxDecodingDepth)
    }
}
