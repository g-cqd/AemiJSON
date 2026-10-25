// A hardening check for patterns that still run on the standard-library `Regex` (a backtracking
// engine): no backreferences, no lookaround / group extensions, and no nested unbounded quantifier
// (`(a+)+`), the catastrophic-backtracking shapes. JSON Schema's `pattern` / `patternProperties` use it
// until they move to a regex engine that has the ECMAScript dialect (JSON Schema patterns are ECMA-262
// flavoured: `^` and `$` are anchors there, which RFC 9485 I-Regexp does not have).
//
// JSONPath's `match()` / `search()` no longer use this file: they run RFC 9485 I-Regexp on AemiRegex,
// which is linear-time for every pattern and checks the RFC's grammar exactly. Measured against that
// grammar on 8,000 generated patterns this check agrees on 6,198, accepts 1,219 the RFC rejects
// (`\d`, `\s`, `\w`, `[a-c-e]`, `a{,2}`) and rejects 583 the RFC accepts (nested quantifiers).
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
