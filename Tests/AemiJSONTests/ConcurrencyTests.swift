import Foundation
import Synchronization
import Testing

@testable import AemiJSON

private struct Row: Codable, Equatable, Sendable {
    var id: Int
    var name: String
    var score: Double
    var tags: [String]
    var active: Bool
}

private func makeRows(_ n: Int) -> [Row] {
    (0 ..< n).map { Row(id: $0, name: "row\($0)", score: Double($0) / 7.0, tags: ["a", "b"], active: $0 % 2 == 0) }
}

@Test func concurrentDecodeMatchesSerial() async throws {
    let rows = makeRows(3000)
    let data = try AemiJSON.JSONEncoder().encode(rows)
    let serial = try AemiJSON.JSONDecoder().decode([Row].self, from: data)
    let concurrent = try await AemiJSON.decodeArrayConcurrently(Row.self, from: data, minimumBatch: 64)
    #expect(serial == rows)
    #expect(concurrent == rows)
    #expect(concurrent == serial)
}

@Test func concurrentDecodeSmallArrayUsesSerialPath() async throws {
    let rows = makeRows(3)
    let data = try AemiJSON.JSONEncoder().encode(rows)
    let out = try await AemiJSON.decodeArrayConcurrently(Row.self, from: data, minimumBatch: 512)
    #expect(out == rows)
}

// MARK: - Structured fan-out: cancellation and no work left behind

// The batches are child tasks of a task group, so cancelling the caller reaches them and the call
// returns only after every batch has stopped. Each test cancels its own task before the call, which
// makes the outcome independent of scheduling. Before, the batches were unstructured tasks that
// ignored the caller's cancellation, and both calls returned every result.

@Test func concurrentDecodeStopsWhenTheCallerIsCancelled() async throws {
    let data = try AemiJSON.JSONEncoder().encode(makeRows(3000))
    for minimumBatch in [64, 5000] {  // fanned out, then the serial path
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AemiJSON.decodeArrayConcurrently(Row.self, from: data, minimumBatch: minimumBatch)
        }
        .result
        #expect(throws: CancellationError.self) { try outcome.get() }
    }
}

@Test func concurrentParseStopsWhenTheCallerIsCancelled() async throws {
    let ndjson = [UInt8]((0 ..< 2000).map { #"{"i":\#($0)}"# }.joined(separator: "\n").utf8)
    for minimumBatch in [64, 5000] {
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AemiJSON.parseLinesConcurrently(ndjson, minimumBatch: minimumBatch)
        }
        .result
        #expect(throws: CancellationError.self) { try outcome.get() }
    }
}

/// Counts the elements being decoded right now, and fails on the element whose `fail` is true.
private struct Tracked: Decodable, Sendable {
    struct Failure: Error {}
    static let live = Atomic<Int>(0)
    init(from decoder: any Decoder) throws {
        Tracked.live.wrappingAdd(1, ordering: .relaxed)
        defer { Tracked.live.wrappingSubtract(1, ordering: .relaxed) }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .fail) { throw Failure() }
    }
    private enum CodingKeys: String, CodingKey {
        case fail
    }
}

@Test func concurrentDecodeLeavesNoBatchRunningAfterAnElementThrows() async throws {
    let elements = (0 ..< 4000).map { #"{"fail":\#($0 == 3)}"# }
    let data = Data(("[" + elements.joined(separator: ",") + "]").utf8)
    await #expect(throws: Tracked.Failure.self) {
        _ = try await AemiJSON.decodeArrayConcurrently(Tracked.self, from: data, minimumBatch: 64)
    }
    #expect(Tracked.live.load(ordering: .relaxed) == 0)
}

@Test func parseMetricsIncrement() throws {
    let before = AemiJSON.Metrics.snapshot()
    _ = try AemiJSON.parse("[1,2,3]")
    let after = AemiJSON.Metrics.snapshot()
    #expect(after.documents >= before.documents + 1)
    #expect(after.bytes >= before.bytes + 7)
}

// MARK: - NDJSON splitting + parallel parse

@Test func ndjsonLinesSplitsTrimsAndSkipsBlanks() {
    let input = [UInt8]("  {\"a\":1}\r\n\n{\"b\":2}\n   \n{\"c\":3}".utf8)
    let lines = AemiJSON.ndjsonLines(input)
    #expect(lines.count == 3)
    #expect(lines[0] == [UInt8](#"{"a":1}"#.utf8))
    #expect(lines[1] == [UInt8](#"{"b":2}"#.utf8))
    #expect(lines[2] == [UInt8](#"{"c":3}"#.utf8))
}

@Test func ndjsonLinesDoesNotSplitOnEscapedNewlineInString() {
    // The bytes hold a backslash-n escape, not a literal 0x0A, so this is one record.
    let input = [UInt8](#"{"a":"x\ny"}"#.utf8)
    let lines = AemiJSON.ndjsonLines(input)
    #expect(lines.count == 1)
    let value = try? JSONValue(AemiJSON.parse(lines[0]).root)
    #expect(value == .object(["a": .string("x\ny")]))
}

@Test func parseLinesConcurrentlyMatchesSerialAndPreservesOrder() async throws {
    let rows = makeRows(2000)
    var ndjson: [UInt8] = []
    for row in rows {
        ndjson.append(contentsOf: try AemiJSON.JSONEncoder().encodeToBytes(row))
        ndjson.append(0x0A)
    }
    let documents = try await AemiJSON.parseLinesConcurrently(ndjson, minimumBatch: 64)
    #expect(documents.count == rows.count)
    let decoder = AemiJSON.JSONDecoder()
    for (i, document) in documents.enumerated() {
        #expect(try decoder.decode(Row.self, from: document) == rows[i])
    }
}

@Test func parseLinesConcurrentlySmallInputUsesSerialPath() async throws {
    let documents = try await AemiJSON.parseLinesConcurrently([UInt8]("1\n2\n3".utf8), minimumBatch: 64)
    #expect(documents.count == 3)
    #expect(documents.map { $0.root.intValue } == [1, 2, 3])
}
