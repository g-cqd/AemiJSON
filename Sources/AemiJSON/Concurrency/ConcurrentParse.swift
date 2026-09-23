import AemiJSONCore
public import AemiRuntime

#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

extension AemiJSON {
    /// Split newline-delimited JSON (NDJSON / JSON Lines) into one `[UInt8]` per record, dropping
    /// blank lines and trimming surrounding ASCII whitespace (so a trailing `\r` from CRLF input is
    /// removed).
    ///
    /// Splitting on the raw `\n` (0x0A) byte is correct for any RFC 8259 / ECMA-404 input: a literal
    /// newline is a control character that a JSON string must escape (`\n`), so a `\n` byte never
    /// appears inside a string token and therefore always separates records. Each returned line owns
    /// its bytes, so the records can be parsed independently across tasks.
    public static func ndjsonLines(_ bytes: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        let n = bytes.count
        var start = 0
        var i = 0
        while i < n {
            if bytes[i] == 0x0A {
                appendTrimmedLine(bytes, start, i, into: &lines)
                start = i + 1
            }
            i += 1
        }
        appendTrimmedLine(bytes, start, n, into: &lines)
        return lines
    }

    /// Trim leading/trailing ASCII whitespace from `bytes[lo..<hi]` and append it as an owned
    /// `[UInt8]` unless the trimmed range is empty.
    private static func appendTrimmedLine(_ bytes: [UInt8], _ lo: Int, _ hi: Int, into lines: inout [[UInt8]]) {
        var a = lo
        var b = hi
        while a < b, isASCIIWhitespace(bytes[a]) { a += 1 }
        while b > a, isASCIIWhitespace(bytes[b - 1]) { b -= 1 }
        if a < b { lines.append([UInt8](bytes[a ..< b])) }
    }

    @inline(__always)
    private static func isASCIIWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    /// Parse newline-delimited JSON (NDJSON / JSON Lines): split `bytes` into records on `\n` (see
    /// ``ndjsonLines(_:)``) then parse the independent records in parallel across cores, off the main
    /// actor. Each record parses to its own immutable, `Sendable` ``JSONDocument``; results are
    /// returned in input order.
    ///
    /// Each record is a separate top-level document, so — unlike parsing a single document, where the
    /// tape is one sequential dependency chain — the records have no data dependency and fan out
    /// cleanly. ``AemiJSON/parse(_:options:)-([UInt8],_)`` is a pure function of its bytes, so nothing mutable crosses the
    /// task boundary. The batches run as child tasks of a task group, so the call returns only once
    /// every batch has stopped. A record that fails to parse surfaces the first error and cancels the
    /// other batches, and cancelling the calling task cancels them too; each stops within 64 records
    /// with a `CancellationError`.
    ///
    /// - Important: `minimumBatch` is the fan-out floor in records. At or below it the records parse
    ///   serially on the calling task; above it they are split into
    ///   `min(coreCount, count / minimumBatch)` batches.
    public static func parseLinesConcurrently(
        _ bytes: [UInt8], options: JSONParseOptions = .strict, minimumBatch: Int = 64
    ) async throws -> [JSONDocument] {
        let lines = ndjsonLines(bytes)
        let n = lines.count
        if n <= minimumBatch {
            return try parseRecords(lines, 0, n, options: options)
        }

        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunkCount = min(cores, max(1, n / minimumBatch))
        let chunkSize = (n + chunkCount - 1) / chunkCount

        // One child task per batch of records. Each reports its batch number, so the batches are
        // reassembled in input order whatever order they finish in.
        return try await withThrowingTaskGroup(of: (batch: Int, documents: [JSONDocument]).self) { group in
            var batches = 0
            for lo in stride(from: 0, to: n, by: chunkSize) {
                let batch = batches
                group.addTask { (batch, try parseRecords(lines, lo, min(lo + chunkSize, n), options: options)) }
                batches += 1
            }
            var parts = [[JSONDocument]](repeating: [], count: batches)
            for try await part in group { parts[part.batch] = part.documents }
            var out: [JSONDocument] = []
            out.reserveCapacity(n)
            for part in parts { out.append(contentsOf: part) }
            return out
        }
    }

    @available(*, deprecated, message: "The batches run in a task group; the task provider is no longer used")
    public static func parseLinesConcurrently(
        _ bytes: [UInt8], options: JSONParseOptions = .strict, minimumBatch: Int = 64, taskProvider: any TaskProvider
    ) async throws -> [JSONDocument] {
        try await parseLinesConcurrently(bytes, options: options, minimumBatch: minimumBatch)
    }

    /// Parses `lines[lo ..< hi]`, checking for cancellation of the current task every 64 records,
    /// starting with the first.
    private static func parseRecords(
        _ lines: [[UInt8]], _ lo: Int, _ hi: Int, options: JSONParseOptions
    ) throws -> [JSONDocument] {
        var documents: [JSONDocument] = []
        documents.reserveCapacity(hi - lo)
        for k in lo ..< hi {
            if (k - lo) & 63 == 0 { try Task.checkCancellation() }
            documents.append(try AemiJSON.parse(lines[k], options: options))
        }
        return documents
    }

    /// `Data` convenience for ``parseLinesConcurrently(_:options:minimumBatch:)``.
    public static func parseLinesConcurrently(
        _ data: Data, options: JSONParseOptions = .strict, minimumBatch: Int = 64
    ) async throws -> [JSONDocument] {
        try await parseLinesConcurrently([UInt8](data), options: options, minimumBatch: minimumBatch)
    }
}
