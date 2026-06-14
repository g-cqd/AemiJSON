import Synchronization

extension ADJSON {
    /// Process-wide, lock-free parse metrics using `Synchronization.Atomic`.
    /// `Sendable` and never touches the main actor.
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
    }
}
