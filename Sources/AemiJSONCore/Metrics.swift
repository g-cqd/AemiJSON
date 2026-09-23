import Synchronization

extension AemiJSON {
    /// Process-wide, lock-free parse metrics using `Synchronization.Atomic`.
    /// `Sendable` and never touches the main actor.
    ///
    /// Recording is **opt-in**: set ``isEnabled`` for a measurement window. Each recorded parse makes
    /// two atomic adds on counters that every parsing thread shares, so parses running at once on
    /// several cores contend for one cache line, for figures only diagnostics read. Disabled, a parse
    /// only loads the flag, which no parse writes. Use ``reset()`` to zero the counters for a fresh
    /// window or to isolate a test; ``snapshot()`` reads them.
    public enum Metrics {
        private static let recording = Atomic<Bool>(false)
        private static let documentsParsed = Atomic<Int>(0)
        private static let bytesParsed = Atomic<Int>(0)

        /// Whether parses are counted. Off by default.
        public static var isEnabled: Bool {
            get { recording.load(ordering: .relaxed) }
            set { recording.store(newValue, ordering: .relaxed) }
        }

        @inline(__always)
        static func record(bytes count: Int) {
            guard recording.load(ordering: .relaxed) else { return }
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
