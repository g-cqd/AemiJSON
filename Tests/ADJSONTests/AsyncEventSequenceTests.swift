import ADTestKit
import Testing

@testable import ADJSON

// A minimal `AsyncSequence` of bytes for driving `JSONEventAsyncSequence` in tests.
private struct ByteStream: AsyncSequence, Sendable {
    typealias Element = UInt8
    let bytes: [UInt8]
    struct Iterator: AsyncIteratorProtocol {
        let bytes: [UInt8]
        var i = 0
        mutating func next() async -> UInt8? {
            guard i < bytes.count else { return nil }
            defer { i += 1 }
            return bytes[i]
        }
    }
    func makeAsyncIterator() -> Iterator { Iterator(bytes: bytes) }
}

private func syncEvents(_ json: String) throws -> [JSONEvent] {
    var reader = JSONEventStreamReader()
    var events = try reader.feed(Array(json.utf8))
    events.append(contentsOf: try reader.finish())
    return events
}

private func asyncEvents(_ json: String, chunkSize: Int) async throws -> [JSONEvent] {
    var out: [JSONEvent] = []
    let seq = JSONEventAsyncSequence(ByteStream(bytes: Array(json.utf8)), chunkSize: chunkSize)
    for try await event in seq { out.append(event) }
    return out
}

@Test func asyncSequenceYieldsExpectedEvents() async throws {
    let json = #"{"a":1,"b":[true,null,"x"]}"#
    let events = try await asyncEvents(json, chunkSize: 4)
    #expect(
        events == [
            .beginObject, .key("a"), .number(1), .key("b"), .beginArray,
            .bool(true), .null, .string("x"), .endArray, .endObject
        ])
}

@Test func asyncSequenceMatchesSyncAcrossChunkSizes() async throws {
    let json = #"{"users":[{"id":1,"name":"a\nb"},{"id":2,"name":"😀"}],"count":2,"ok":true,"n":null}"#
    let expected = try syncEvents(json)
    for chunkSize in [1, 2, 3, 5, 13, 64, 4096] {
        let got = try await asyncEvents(json, chunkSize: chunkSize)
        #expect(got == expected, "mismatch at chunkSize \(chunkSize)")
    }
}

@Test func asyncSequencePropagatesParseError() async throws {
    await #expect(throws: JSONError.self) {
        _ = try await asyncEvents(#"{"a":}"#, chunkSize: 2)  // malformed
    }
    // Truncated input surfaces on finish().
    await #expect(throws: JSONError.self) {
        _ = try await asyncEvents(#"{"a":1"#, chunkSize: 8)
    }
}

@Test func asyncSequenceStreamsDeeplyNestedWithoutOverflow() async throws {
    let depth = 5_000
    let json = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
    var begins = 0
    let seq = JSONEventAsyncSequence(
        ByteStream(bytes: Array(json.utf8)), options: JSONParseOptions(maxDepth: depth + 1), chunkSize: 256)
    for try await event in seq where event == .beginArray { begins += 1 }
    #expect(begins == depth)
}

@Test func asyncProbeObservesExactEventSequence() async throws {
    // A driver task records each streamed event into an `AsyncEventProbe`; the test suspends until the
    // exact expected count lands, then inspects the recorded events for full order — a
    // suspend-until-count boundary plus event introspection that native `Confirmation`
    // (count-within-a-closure, no event capture, no stall diagnostic) cannot express.
    let json = #"{"a":1,"b":[true,null,"x"]}"#
    let expected: [JSONEvent] = [
        .beginObject, .key("a"), .number(1), .key("b"), .beginArray,
        .bool(true), .null, .string("x"), .endArray, .endObject
    ]
    let probe = AsyncEventProbe<JSONEvent>()
    let driver = Task {
        let seq = JSONEventAsyncSequence(ByteStream(bytes: Array(json.utf8)), chunkSize: 4)
        for try await event in seq { probe.record(event) }
    }
    let observed = try await probe.wait(forAtLeast: expected.count)
    expectEqual(observed, expected)
    try await driver.value  // surface any parse error and confirm the stream completed cleanly
}
