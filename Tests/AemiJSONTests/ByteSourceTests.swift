import AemiJSON
import Foundation
import Synchronization
import Testing

// A document parsed from a `ByteSource` keeps the source and borrows its bytes again on every read,
// trusting the tape's offsets. The length the parse validated must therefore be the length it parsed,
// and a later borrow that lends a different length must stop the read rather than run past the end.

/// Lends `full` until `shrink()` is called, then a one-byte buffer: a source that breaks the
/// `ByteSource` rule that every borrow sees the same bytes. Counts its borrows.
private final class ShrinkableSource: ByteSource, Sendable {
    private let full: [UInt8]
    private let shrunk: [UInt8] = [0x7B]
    private let isShrunk = Atomic<Bool>(false)
    private let borrowCount = Atomic<Int>(0)

    init(_ text: String) { full = Array(text.utf8) }

    var borrows: Int { borrowCount.load(ordering: .relaxed) }
    func shrink() { isShrunk.store(true, ordering: .relaxed) }

    func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        borrowCount.wrappingAdd(1, ordering: .relaxed)
        return try (isShrunk.load(ordering: .relaxed) ? shrunk : full).withUnsafeBytes(body)
    }
}

private let document = #"{"k":"a value long enough to sit past a one-byte buffer"}"#

struct ByteSourceTests {
    // Before, the parse borrowed once to check the length and again to build the tape, so the check
    // and the parse could see different bytes.
    @Test func parseBorrowsTheSourceOnce() throws {
        let source = ShrinkableSource(document)
        let parsed = try AemiJSON.parse(source)
        #expect(source.borrows == 1)
        #expect(parsed.root["k"].string == "a value long enough to sit past a one-byte buffer")
    }

    // Before, the read borrowed the one-byte buffer and followed the tape's offsets past its end.
    @Test func readingASourceThatShrankTraps() async {
        await #expect(processExitsWith: .failure) {
            let source = ShrinkableSource(document)
            let parsed = try AemiJSON.parse(source)
            source.shrink()
            _ = parsed.root["k"].string
        }
    }
}
