// Shared RFC 9485 I-Regexp safe-subset utilities, exposed at `package` scope so both JSONPath's
// `match()` / `search()` and JSON Schema's `pattern` / `patternProperties` enforce the *same* trust
// boundary before any attacker-influenced pattern reaches the standard-library `Regex` (a backtracking
// engine): no backreferences, no lookaround / group extensions, and no nested unbounded quantifier
// (`(a+)+`) — the catastrophic-backtracking shapes. JSON Schema (Draft 2020-12 §6.4) likewise
// recommends restricting `pattern` to an interoperable regex subset, so this is conformance-aligned,
// not only a hardening measure. The implementation lives with the JSONPath evaluator; this is the
// cross-module entry point.
package enum IRegexp {
    /// A human-readable reason `pattern` falls outside the I-Regexp safe subset, or `nil` if it is
    /// acceptable to compile and run.
    package static func rejectionReason(_ pattern: String) -> String? {
        JSONPathEvaluator.iRegexpRejectionReason(pattern)
    }

    /// Translate an I-Regexp pattern into the equivalent standard-library `Regex` source.
    package static func toSwift(_ pattern: String) -> String {
        JSONPathEvaluator.iRegexpToSwift(pattern)
    }
}
