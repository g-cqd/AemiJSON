public import AemiRuntime

#if canImport(Darwin)
    internal import Darwin
#elseif canImport(Glibc)
    internal import Glibc
#elseif canImport(Musl)
    internal import Musl
#endif

/// A file descriptor's bytes in blocks, read on a thread of an offload pool so a blocking `read` never holds a thread of the cooperative
/// pool. One `read` per block, not per byte. Ends at end of file; the descriptor is neither owned nor closed.
public struct FileDescriptorChunks: AsyncSequence, Sendable {
    public typealias Element = [UInt8]
    public typealias Failure = any Error

    /// The default block size, in bytes.
    public static let defaultBlockSize = 64 << 10

    /// A `read` failed.
    public struct ReadError: Error, Sendable, Equatable {
        /// The `errno` it failed with.
        public let code: Int32
    }

    let descriptor: Int32
    let blockSize: Int
    let pool: BlockingOffloadPool

    /// The blocks of `descriptor`, each at most `blockSize` bytes, read on `pool`.
    public init(descriptor: Int32, blockSize: Int = defaultBlockSize, pool: BlockingOffloadPool) {
        precondition(blockSize > 0, "a block holds at least one byte")
        self.descriptor = descriptor
        self.blockSize = blockSize
        self.pool = pool
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let chunks: FileDescriptorChunks
        private var ended = false

        init(_ chunks: FileDescriptorChunks) { self.chunks = chunks }

        public mutating func next() async throws -> [UInt8]? {
            guard !ended else { return nil }
            let (descriptor, size) = (chunks.descriptor, chunks.blockSize)
            let block = try await chunks.pool.run { try Self.read(descriptor, size) }
            guard !block.isEmpty else {
                ended = true
                return nil
            }
            return block
        }

        /// One block of `descriptor`; empty at end of file.
        private static func read(_ descriptor: Int32, _ size: Int) throws -> [UInt8] {
            var block = [UInt8](repeating: 0, count: size)
            while true {
                let count = block.withUnsafeMutableBytes { raw in
                    unsafe readBytes(descriptor, raw.baseAddress, raw.count)
                }
                if count >= 0 {
                    block.removeSubrange(count...)
                    return block
                }
                guard errno == EINTR else { throw ReadError(code: errno) }
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(self) }
}

@unsafe private func readBytes(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    unsafe read(descriptor, buffer, count)
}
