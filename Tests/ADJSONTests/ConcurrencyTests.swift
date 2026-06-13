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
    (0..<n).map { Row(id: $0, name: "row\($0)", score: Double($0) / 7.0, tags: ["a", "b"], active: $0 % 2 == 0) }
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

@Test func parseMetricsIncrement() throws {
    let before = ADJSONMetrics.snapshot()
    _ = try ADJSON.parse("[1,2,3]")
    let after = ADJSONMetrics.snapshot()
    #expect(after.documents >= before.documents + 1)
    #expect(after.bytes >= before.bytes + 7)
}
