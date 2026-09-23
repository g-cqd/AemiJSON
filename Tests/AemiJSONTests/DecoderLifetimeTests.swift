import AemiJSON
import Foundation
import Testing

// The tape decoder reads through pointers borrowed for one decode call. A `Decoder` can outlive that
// call — a `Decodable` may keep it to read from later, as Foundation's decoder tolerates — and a read
// through it must then trap rather than follow pointers into memory that may already be gone.

/// Keeps the decoder it was created with, reading nothing during the decode.
private struct KeptDecoder: Decodable {
    let decoder: any Decoder
    init(from decoder: any Decoder) throws { self.decoder = decoder }
}

private enum Key: String, CodingKey {
    case a
}

private func parseInPlace<Source: ByteSource & Sendable>(_ source: Source) throws -> JSONDocument {
    try AemiJSON.parse(source)
}

private let document = #"{"a":1}"#

/// Decodes `{"a":1}` into a `KeptDecoder`, either from a parse that owns a copy of the bytes or from
/// one that reads a `Data` in place. At 7 bytes that `Data` stores its payload inline, so its borrow
/// lends a temporary copy.
private func keepDecoder(readingInPlace: Bool) throws -> KeptDecoder {
    let data = Data(document.utf8)
    let parsed = readingInPlace ? try parseInPlace(data) : try AemiJSON.parse(data)
    return try AemiJSON.JSONDecoder().decode(KeptDecoder.self, from: parsed)
}

struct DecoderLifetimeTests {
    @Test func decodingAValueThatKeepsItsDecoderSucceeds() throws {
        _ = try keepDecoder(readingInPlace: false)
        _ = try keepDecoder(readingInPlace: true)
    }

    // Before the guard, the owned-copy read returned 1 and the process exited cleanly; the in-place
    // read went through a pointer to a temporary copy of the inline `Data` bytes.
    @Test func readingThroughAKeptDecoderTraps() async {
        await #expect(processExitsWith: .failure) {
            let kept = try keepDecoder(readingInPlace: false)
            _ = try kept.decoder.container(keyedBy: Key.self).decode(Int.self, forKey: .a)
        }
        await #expect(processExitsWith: .failure) {
            let kept = try keepDecoder(readingInPlace: true)
            _ = try kept.decoder.container(keyedBy: Key.self).decode(Int.self, forKey: .a)
        }
    }
}
