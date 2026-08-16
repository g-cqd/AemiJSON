import AemiKernel

/// Reusable scratch buffers for the encoder, backed by a shared ``AemiKernel/ByteBufferPool``.
/// Cuts allocation churn when many values are encoded (e.g. a server hot path).
enum EncoderBufferPool {
    // Cap on a recycled buffer's retained capacity (1 MiB) and on the pool size (32): without them a
    // single oversized encode would keep large allocations alive for the process lifetime.
    private static let pool = ByteBufferPool(maxBufferCapacity: 1 << 20, maxPooled: 32)

    static func take() -> [UInt8] { pool.take() }

    static func recycle(_ buffer: [UInt8]) { pool.recycle(buffer) }
}
