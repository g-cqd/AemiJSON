import ADJSONCore
public import Foundation

extension JSONDocument {
    /// Tape indices of each top-level array element (single pass), or nil if the
    /// root isn't an array.
    func topLevelArrayElementStarts() -> [Int]? {
        guard !tape.isEmpty, Slot.tag(tape[0]) == JSONKind.array.rawValue else { return nil }
        let count = Slot.count(tape[0])
        var out = [Int]()
        out.reserveCapacity(count)
        var i = 1
        for _ in 0..<count {
            out.append(i)
            let s = tape[i]
            let t = Slot.tag(s)
            i = (t == JSONKind.object.rawValue || t == JSONKind.array.rawValue) ? Slot.low(s) : i + 1
        }
        return out
    }

    /// Decode a contiguous range of array elements. Each call binds its own base
    /// pointer over the shared immutable storage, so it is safe to run from many
    /// tasks at once.
    func decodeElementRange<T: Decodable>(_ type: T.Type, _ lo: Int, _ hi: Int, _ starts: [Int]) throws -> [T] {
        try withBuffers { byteBase, byteCount, tapeBase, tapeCount in
            let ctx = DecodeContext(
                doc: self, bytes: byteBase, byteCount: byteCount,
                tape: tapeBase, tapeCount: tapeCount, userInfo: [:])
            var out = [T]()
            out.reserveCapacity(hi - lo)
            for k in lo..<hi { out.append(try ctx.decodeValue(T.self, at: starts[k])) }
            return out
        }
    }
}

extension ADJSON {
    /// Decode a top-level JSON array, scanning once on the calling task then
    /// decoding element batches in parallel across cores. Off the main actor.
    /// Static (no decoder instance) so nothing non-Sendable crosses isolation.
    public static func decodeArrayConcurrently<T: Decodable & Sendable>(
        _ type: T.Type, from data: Data, minimumBatch: Int = 512
    ) async throws -> [T] {
        try await decodeArrayConcurrently(type, from: try ADJSON.parse(data), minimumBatch: minimumBatch)
    }

    public static func decodeArrayConcurrently<T: Decodable & Sendable>(
        _ type: T.Type, from document: JSONDocument, minimumBatch: Int = 512
    ) async throws -> [T] {
        guard let starts = document.topLevelArrayElementStarts() else {
            return try JSONDecoder().decode([T].self, from: document)
        }
        let n = starts.count
        if n <= minimumBatch {
            return try document.decodeElementRange(T.self, 0, n, starts)
        }
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunkCount = min(cores, max(1, n / minimumBatch))
        let chunkSize = (n + chunkCount - 1) / chunkCount

        return try await withThrowingTaskGroup(of: (Int, [T]).self) { group in
            var chunkIndex = 0
            var lo = 0
            while lo < n {
                let hi = min(lo + chunkSize, n)
                let lo0 = lo
                let idx = chunkIndex
                group.addTask {
                    (idx, try document.decodeElementRange(T.self, lo0, hi, starts))
                }
                lo = hi
                chunkIndex += 1
            }
            var parts = [[T]?](repeating: nil, count: chunkIndex)
            for try await (i, part) in group { parts[i] = part }
            var out = [T]()
            out.reserveCapacity(n)
            for p in parts { out.append(contentsOf: p ?? []) }
            return out
        }
    }
}
