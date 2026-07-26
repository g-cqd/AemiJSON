public import ADConcurrency
import ADJSONCore
#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

extension ADJSON {
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
    /// cleanly. ``ADJSON/parse(_:options:)-([UInt8],_)`` is a pure function of its bytes, so nothing mutable crosses the
    /// task boundary. Records that fail to parse surface the first error (the throwing task group
    /// cancels the rest).
    ///
    /// - Important: `minimumBatch` is the fan-out floor in records. At or below it the records parse
    ///   serially on the calling task; above it they are split into
    ///   `min(coreCount, count / minimumBatch)` batches.
    public static func parseLinesConcurrently(
        _ bytes: [UInt8], options: JSONParseOptions = .strict, minimumBatch: Int = 64,
        taskProvider: any TaskProvider = LiveTaskProvider()
    ) async throws -> [JSONDocument] {
        let lines = ndjsonLines(bytes)
        let n = lines.count
        if n <= minimumBatch {
            return try lines.map { try ADJSON.parse($0, options: options) }
        }

        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunkCount = min(cores, max(1, n / minimumBatch))
        let chunkSize = (n + chunkCount - 1) / chunkCount

        // Spawn one `.work` task per chunk through the injected provider (live = `Task.init`), holding
        // the handles in chunk order, then gather them in order — preserving the input order the former
        // `(index, part)` task-group collection produced. A test injects a `TaskProviderSpy` and
        // `await waitForAllTasks()` to settle these handles deterministically.
        var handles: [Task<[JSONDocument], any Error>] = []
        handles.reserveCapacity(chunkCount)
        var lo = 0
        while lo < n {
            let hi = min(lo + chunkSize, n)
            let lo0 = lo
            handles.append(
                taskProvider.task(role: .work) {
                    var docs: [JSONDocument] = []
                    docs.reserveCapacity(hi - lo0)
                    for k in lo0 ..< hi { docs.append(try ADJSON.parse(lines[k], options: options)) }
                    return docs
                })
            lo = hi
        }
        var out: [JSONDocument] = []
        out.reserveCapacity(n)
        do {
            for handle in handles { out.append(contentsOf: try await handle.value) }
        } catch {
            for handle in handles { handle.cancel() }  // first error cancels the rest, as the group did
            throw error
        }
        return out
    }

    /// `Data` convenience for ``parseLinesConcurrently(_:options:minimumBatch:)``.
    public static func parseLinesConcurrently(
        _ data: Data, options: JSONParseOptions = .strict, minimumBatch: Int = 64
    ) async throws -> [JSONDocument] {
        try await parseLinesConcurrently([UInt8](data), options: options, minimumBatch: minimumBatch)
    }
}
