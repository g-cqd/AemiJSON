import Synchronization

/// Reusable scratch buffers for the encoder, guarded by `Synchronization.Mutex`.
/// Cuts allocation churn when many values are encoded (e.g. a server hot path).
enum EncoderBufferPool {
    static let storage = Mutex<[[UInt8]]>([])

    /// Cap on a recycled buffer's retained capacity. Without it, a single oversized encode would
    /// keep up to `maxPooled` large allocations alive for the process lifetime; buffers grown past
    /// this are dropped (their capacity released) instead of pooled.
    static let maxBufferCapacity = 1 << 20  // 1 MiB
    static let maxPooled = 32

    static func take() -> [UInt8] {
        (storage.withLock { $0.popLast() }) ?? []
    }

    static func recycle(_ buffer: [UInt8]) {
        guard buffer.capacity <= maxBufferCapacity else { return }
        var b = buffer
        b.removeAll(keepingCapacity: true)
        storage.withLock { pool in
            if pool.count < maxPooled { pool.append(b) }
        }
    }
}
