#if DEBUG
    /// Counts the key comparisons of the decodes run while it is bound (debug builds only), so a test can bound the work of a member lookup
    /// without timing it. A context reads the binding once, when it is made; release builds have neither the type nor the reads.
    @usableFromInline
    final class KeyComparisonCounter: @unchecked Sendable {
        // A decode is synchronous and the counter is bound to one task: nothing else writes it while the decode runs.
        @usableFromInline var count = 0

        init() {}

        @TaskLocal static var current: KeyComparisonCounter?
    }
#endif
