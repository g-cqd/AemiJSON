import Synchronization

extension ADJSON {
    /// Process-wide, lock-free parse metrics using `Synchronization.Atomic`.
    /// `Sendable` and never touches the main actor.
    ///
    /// Recording is **unconditional** rather than opt-in on purpose: it is two `relaxed` atomic adds
    /// **per parsed document** (not per byte), off any hot inner loop, so the cost is below the noise
    /// floor of a parse — gating it behind a flag would add a branch that costs more than the work it
    /// guards. Use ``reset()`` to zero the counters for a fresh measurement window or to isolate a
    /// test; ``snapshot()`` reads them.
    public enum Metrics {
        private static let documentsParsed = Atomic<Int>(0)
        private static let bytesParsed = Atomic<Int>(0)

        @inline(__always)
        static func record(bytes count: Int) {
            _ = documentsParsed.wrappingAdd(1, ordering: .relaxed)
            _ = bytesParsed.wrappingAdd(count, ordering: .relaxed)
        }

        public static func snapshot() -> (documents: Int, bytes: Int) {
            (documentsParsed.load(ordering: .relaxed), bytesParsed.load(ordering: .relaxed))
        }

        /// Zero the counters — for a fresh measurement window, or to isolate metrics in a test.
        public static func reset() {
            documentsParsed.store(0, ordering: .relaxed)
            bytesParsed.store(0, ordering: .relaxed)
        }
    }
}
