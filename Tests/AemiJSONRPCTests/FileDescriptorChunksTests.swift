import AemiJSONRPC
import AemiRuntime
import Foundation
import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Writes all of `bytes` to `descriptor`, then closes it. Typed, outside the test body, so the body type-checks well
/// under the package's 100 ms budget (the closure inside a `Thread` initializer took 102 ms inline).
private func writeAll(_ bytes: [UInt8], to descriptor: Int32) {
    var offset = 0
    while offset < bytes.count {
        let written: Int = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(descriptor, base + offset, raw.count - offset)
        }
        guard written > 0 else { break }
        offset += written
    }
    close(descriptor)
}

/// Writes `bytes` to the write end of a new pipe on a thread of its own and returns the read end.
private func pipeFeeding(_ bytes: [UInt8]) -> Int32 {
    var ends: [Int32] = [0, 0]
    precondition(pipe(&ends) == 0, "pipe failed")
    let writeEnd: Int32 = ends[1]
    let writer = Thread { writeAll(bytes, to: writeEnd) }
    writer.start()
    return ends[0]
}

/// `count` bytes counting up and wrapping.
private func countingBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    for index in 0 ..< count { bytes[index] = UInt8(truncatingIfNeeded: index) }
    return bytes
}

@Suite struct FileDescriptorChunksTests {
    /// What is written to a pipe comes out in blocks, whole, then the sequence ends.
    @Test func readsAPipeToItsEnd() async throws {
        let payload = countingBytes(200_000)
        let readEnd = pipeFeeding(payload)
        let pool = BlockingOffloadPool(width: 1)
        defer { pool.shutdown() }
        var received: [UInt8] = []
        var sizes: [Int] = []
        for try await chunk in FileDescriptorChunks(descriptor: readEnd, pool: pool) {
            received += chunk
            sizes.append(chunk.count)
        }
        close(readEnd)
        let whole: Bool = received == payload
        let largest: Int = sizes.max() ?? 0
        #expect(whole)
        #expect(largest <= FileDescriptorChunks.defaultBlockSize)
        #expect(sizes.count >= 4)
    }
}
