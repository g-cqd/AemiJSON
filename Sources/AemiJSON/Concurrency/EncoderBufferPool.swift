import AemiKernel

/// Reusable scratch buffers for the encoder, backed by a shared ``AemiKernel/ByteBufferPool``.
/// Cuts allocation churn when many values are encoded (e.g. a server hot path).
enum EncoderBufferPool {
    // Cap on a recycled buffer's retained capacity (1 MiB) and on the pool size (32): without them a
    // single oversized encode would keep large allocations alive for the process lifetime.
    private static let pool = ByteBufferPool(maxBufferCapacity: 1 << 20, maxPooled: 32)

    static func take() -> [UInt8] { pool.take() }

    /// Takes ownership, like the pool itself: a buffer still shared with the caller would make the
    /// pool's in-place clear copy it instead of reusing its storage.
    static func recycle(_ buffer: consuming [UInt8]) { pool.recycle(consume buffer) }
}
