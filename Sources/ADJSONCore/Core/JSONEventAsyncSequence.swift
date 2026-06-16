// An `AsyncSequence` adapter over the resumable push reader (`JSONEventStreamReader`), so a stream of
// UTF-8 bytes can be consumed as `JSONEvent`s with `for try await`. Foundation-free: it is generic
// over any `AsyncSequence` of `UInt8`, which is exactly what `URLSession.AsyncBytes` and
// `FileHandle.AsyncBytes` already are — so they compose directly, no extra dependency.

/// An `AsyncSequence` of ``JSONEvent``s decoded incrementally from an async stream of UTF-8 bytes.
///
/// Bytes are pulled in batches and fed to a resumable ``JSONEventStreamReader``, so a document of any
/// size streams through without ever being held whole in memory, and nesting is bounded by
/// ``JSONParseOptions/maxDepth`` rather than the call stack.
///
/// ```swift
/// let (bytes, _) = try await URLSession.shared.bytes(from: url)
/// for try await event in JSONEventAsyncSequence(bytes) {
///     // handle each JSONEvent as it arrives
/// }
/// ```
public struct JSONEventAsyncSequence<Source: AsyncSequence>: AsyncSequence where Source.Element == UInt8 {
    public typealias Element = JSONEvent

    @usableFromInline let source: Source
    @usableFromInline let options: JSONParseOptions
    @usableFromInline let chunkSize: Int

    /// - Parameters:
    ///   - source: an async sequence of UTF-8 bytes (e.g. `URLSession.AsyncBytes`).
    ///   - options: parse profile (default `.strict`); `maxDepth` bounds container nesting.
    ///   - chunkSize: bytes pulled before each `feed` (default 16 KiB). Larger amortizes the per-feed
    ///     overhead; smaller lowers latency to the first event.
    public init(_ source: Source, options: JSONParseOptions = .strict, chunkSize: Int = 16 * 1024) {
        self.source = source
        self.options = options
        self.chunkSize = Swift.max(1, chunkSize)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(source: source.makeAsyncIterator(), options: options, chunkSize: chunkSize)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var sourceIterator: Source.AsyncIterator
        var reader: JSONEventStreamReader
        var pending: [JSONEvent]
        var pendingIndex: Int
        var sourceExhausted: Bool
        var finished: Bool
        let chunkSize: Int

        init(source: Source.AsyncIterator, options: JSONParseOptions, chunkSize: Int) {
            sourceIterator = source
            reader = JSONEventStreamReader(options: options)
            pending = []
            pendingIndex = 0
            sourceExhausted = false
            finished = false
            self.chunkSize = chunkSize
        }

        public mutating func next() async throws -> JSONEvent? {
            while true {
                if pendingIndex < pending.count {
                    defer { pendingIndex += 1 }
                    return pending[pendingIndex]
                }
                if finished { return nil }
                pending.removeAll(keepingCapacity: true)
                pendingIndex = 0
                if sourceExhausted {
                    // No more input: flush the reader (validates a complete document; throws if truncated).
                    pending = try reader.finish()
                    finished = true
                    continue
                }
                var chunk = [UInt8]()
                chunk.reserveCapacity(chunkSize)
                while chunk.count < chunkSize, let byte = try await sourceIterator.next() {
                    chunk.append(byte)
                }
                if chunk.count < chunkSize { sourceExhausted = true }  // source ran out mid-chunk
                if chunk.isEmpty { continue }  // nothing pulled → drain via finish() on the next pass
                pending = try reader.feed(chunk)
            }
        }
    }
}

extension JSONEventAsyncSequence: Sendable where Source: Sendable {}
