import ADTestKit
import Foundation
import Testing

@testable import ADJSON

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
    let data = try ADJSON.JSONEncoder().encode(rows)
    let serial = try ADJSON.JSONDecoder().decode([Row].self, from: data)
    let concurrent = try await ADJSON.decodeArrayConcurrently(Row.self, from: data, minimumBatch: 64)
    #expect(serial == rows)
    #expect(concurrent == rows)
    #expect(concurrent == serial)
}

@Test func concurrentDecodeSmallArrayUsesSerialPath() async throws {
    let rows = makeRows(3)
    let data = try ADJSON.JSONEncoder().encode(rows)
    let out = try await ADJSON.decodeArrayConcurrently(Row.self, from: data, minimumBatch: 512)
    #expect(out == rows)
}

// MARK: - TaskProvider seam (deterministic spy settling)

@Test func concurrentDecodeSettlesViaTaskProviderSpy() async throws {
    // Inject the kit's spy: it spawns the real `.work` tasks (so the decode actually runs) while
    // tracking them, then settles deterministically — no real-time wait, no serial-result race.
    let rows = makeRows(3000)
    let data = try ADJSON.JSONEncoder().encode(rows)
    let spy = TaskProviderSpy()
    let decoded = try await ADJSON.decodeArrayConcurrently(
        Row.self, from: data, minimumBatch: 64, taskProvider: spy)
    try await spy.waitForAllTasks()
    #expect(decoded == rows)  // correct AND in input order (the manual ordered gather)
    #expect(spy.spawnedCount > 1, "the fan-out spawned more than one chunk task")
    #expect(spy.liveCount == 0, "every spawned `.work` task settled")
}

@Test func concurrentParseSettlesViaTaskProviderSpy() async throws {
    let recordCount = 2000
    let ndjson = (0 ..< recordCount).map { #"{"i":\#($0)}"# }.joined(separator: "\n")
    let spy = TaskProviderSpy()
    let docs = try await ADJSON.parseLinesConcurrently(
        [UInt8](ndjson.utf8), minimumBatch: 64, taskProvider: spy)
    try await spy.waitForAllTasks()  // deterministic settle — no real-time wait
    #expect(docs.count == recordCount)
    #expect(spy.spawnedCount > 1, "the fan-out spawned more than one chunk task")
    #expect(spy.liveCount == 0, "every spawned `.work` task settled")
}

@Test func parseMetricsIncrement() throws {
    let before = ADJSON.Metrics.snapshot()
    _ = try ADJSON.parse("[1,2,3]")
    let after = ADJSON.Metrics.snapshot()
    #expect(after.documents >= before.documents + 1)
    #expect(after.bytes >= before.bytes + 7)
}

// MARK: - NDJSON splitting + parallel parse

@Test func ndjsonLinesSplitsTrimsAndSkipsBlanks() {
    let input = [UInt8]("  {\"a\":1}\r\n\n{\"b\":2}\n   \n{\"c\":3}".utf8)
    let lines = ADJSON.ndjsonLines(input)
    #expect(lines.count == 3)
    #expect(lines[0] == [UInt8](#"{"a":1}"#.utf8))
    #expect(lines[1] == [UInt8](#"{"b":2}"#.utf8))
    #expect(lines[2] == [UInt8](#"{"c":3}"#.utf8))
}

@Test func ndjsonLinesDoesNotSplitOnEscapedNewlineInString() {
    // The bytes hold a backslash-n escape, not a literal 0x0A, so this is one record.
    let input = [UInt8](#"{"a":"x\ny"}"#.utf8)
    let lines = ADJSON.ndjsonLines(input)
    #expect(lines.count == 1)
    let value = try? JSONValue(ADJSON.parse(lines[0]).root)
    #expect(value == .object(["a": .string("x\ny")]))
}

@Test func parseLinesConcurrentlyMatchesSerialAndPreservesOrder() async throws {
    let rows = makeRows(2000)
    var ndjson: [UInt8] = []
    for row in rows {
        ndjson.append(contentsOf: try ADJSON.JSONEncoder().encodeToBytes(row))
        ndjson.append(0x0A)
    }
    let documents = try await ADJSON.parseLinesConcurrently(ndjson, minimumBatch: 64)
    #expect(documents.count == rows.count)
    let decoder = ADJSON.JSONDecoder()
    for (i, document) in documents.enumerated() {
        #expect(try decoder.decode(Row.self, from: document) == rows[i])
    }
}

@Test func parseLinesConcurrentlySmallInputUsesSerialPath() async throws {
    let documents = try await ADJSON.parseLinesConcurrently([UInt8]("1\n2\n3".utf8), minimumBatch: 64)
    #expect(documents.count == 3)
    #expect(documents.map { $0.root.intValue } == [1, 2, 3])
}
