import Synchronization

/// Reusable scratch buffers for the encoder, guarded by `Synchronization.Mutex`.
/// Cuts allocation churn when many values are encoded (e.g. a server hot path).
enum EncoderBufferPool {
    static let storage = Mutex<[[UInt8]]>([])

    static func take() -> [UInt8] {
        (storage.withLock { $0.popLast() }) ?? []
    }

    static func recycle(_ buffer: [UInt8]) {
        var b = buffer
        b.removeAll(keepingCapacity: true)
        storage.withLock { pool in
            if pool.count < 32 { pool.append(b) }
        }
    }
}
