import AemiJSONRPC
import AemiRuntime
import Foundation
import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite struct FileDescriptorChunksTests {
    /// What is written to a pipe comes out in blocks, whole, then the sequence ends.
    @Test func readsAPipeToItsEnd() async throws {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        let payload = (0 ..< 200_000).map { UInt8(truncatingIfNeeded: $0) }
        let (readEnd, writeEnd) = (ends[0], ends[1])
        let writer = Thread {
            payload.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let n = write(writeEnd, base + offset, raw.count - offset)
                    guard n > 0 else { break }
                    offset += n
                }
            }
            close(writeEnd)
        }
        writer.start()
        let pool = BlockingOffloadPool(width: 1)
        defer { pool.shutdown() }
        var received: [UInt8] = []
        var chunks = 0
        for try await chunk in FileDescriptorChunks(descriptor: readEnd, pool: pool) {
            #expect(chunk.count <= FileDescriptorChunks.defaultBlockSize)
            received += chunk
            chunks += 1
        }
        close(readEnd)
        #expect(received == payload)
        #expect(chunks >= 4)
    }
}
