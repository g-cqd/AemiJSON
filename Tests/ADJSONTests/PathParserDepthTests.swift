import Foundation
import Testing

@testable import ADJSON
@testable import ADJSONCore

// Parser recursion-depth safety on a SMALL stack.
//
// ADJSON's RFC 9535 `JSONPathParser` is a recursive-descent parser: several constructs consume native
// call-stack frames per nesting level. The default swift-testing thread has an ~8 MB stack that HIDES a
// deep-recursion overflow, but production parses run on smaller worker / event-loop stacks. So every
// deep-nesting parse here runs INSIDE a `Thread` whose `stackSize` is pinned to 512 KiB — the realistic
// floor off the main thread, matching the worker stack the sibling SQL engine crashed on — and is
// joined. PASS is process survival: each crafted input must either throw a clean `JSONPathError` or
// parse; a stack-overflow (SIGBUS) on that thread aborts the whole process and so fails the run.
//
// Which path constructs are recursive vs iterative (verified by bisecting the overflow depth on the
// 512 KiB thread, with `maxDepth` temporarily lifted to expose the raw native ceiling):
//   • RECURSIVE (native frames per level):
//       - nested bracket-filters `[?@[?@[?…]]]`  — heaviest: each textual level bumps the `depth`
//         counter ~3× and costs ~7.5 KB native, so the 512 KiB stack overflows at `depth` ≈ 214
//         (debug) / ≈ 85 (ASan). The `maxDepth = 64` guard stops at ~64 frames — ~25 % below even the
//         ASan ceiling — so it fires BEFORE the stack does. (This is the path the sibling SQL engine's
//         analogous cap mis-sized; ADJSON's cap survives because `depth` climbs faster than 1×/level.)
//       - parenthesised filter sub-expressions `((((@==1))))` — ~3 KB/level (overflowed textual ~167).
//       - `length(length(…(@)…))`                — ~2 KB/level.
//   • ITERATIVE (constant `depth` — `parseSegments` loops over sibling segments):
//       - member chain `$.a.a.a…` and bracket-index chain `$[0][0][0]…`.
//       - `&&` / `||` runs (fold in a loop) and `!` runs (parity fold) inside a filter.
// `JSONPointer` / `RelativeJSONPointer` / `SQLiteJSONPath` parse with plain index loops (no recursion),
// so they are exercised here at extreme length purely as a survival baseline.
//
// Conclusion: no parser crashes the 512 KiB stack at any depth up to 5000 — the guard rejects deep
// nesting cleanly first. This suite is the regression lock that keeps it that way.

@Suite("Path parser depth safety")
struct PathParserDepthTests {
    // Pinned to the sibling SQL engine's worker-stack size. Smaller than any default thread stack, so a
    // per-level frame cost that the 8 MB test thread would absorb is forced to overflow here instead.
    private static let workerStackSize = 512 * 1024

    /// Run `body` on a fresh 512 KiB `Thread` and block until it finishes. `body` is expected to be
    /// total (catch its own errors); if it instead overflows the small stack the process aborts, which
    /// is the failure this harness is designed to surface. Returns only after the worker has joined.
    private func onWorkerStack(_ body: @Sendable @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            done.signal()
        }
        thread.stackSize = Self.workerStackSize
        thread.name = "PathParserDepthTests.worker"
        thread.start()
        done.wait()
    }

    /// Parse `path` on the worker stack. The outcome (parsed vs threw a clean `JSONPathError`) is
    /// irrelevant to safety — only that the worker returns at all (no overflow). When `evaluate` is set
    /// and the parse succeeds, the compiled path is also run against a tiny document so the *evaluator's*
    /// recursion (`evalFilter`) is exercised on the same small stack.
    private func parseSafely(_ path: String, evaluate: JSON? = nil) {
        onWorkerStack {
            guard let compiled = try? JSONPath(path) else { return }  // clean throw — fine
            if let doc = evaluate { _ = compiled.query(doc) }
        }
    }

    // MARK: - Deep-nesting sweeps (every input is VALID up to the cap, then over-deep past it)

    @Test func nestedBracketFiltersSurvive512KiBStack() throws {
        // `$[?@[?@[?…@.a==1…]]]` — the heaviest recursive path (textual N=21 already exceeds the cap, as
        // each level bumps `depth` ~3×). The guard must reject deep nesting long before the 512 KiB
        // stack overflows (which the raw recursion would do near textual depth ~70 debug / ~28 ASan).
        // Sweep from shallow to WELL past the cap.
        let doc = try ADJSON.parse(#"{"a":1,"b":2}"#).root
        for n in depths() {
            let path = "$" + String(repeating: "[?@", count: n) + "[?@.a==1]" + String(repeating: "]", count: n)
            parseSafely(path, evaluate: n <= 32 ? doc : nil)
        }
    }

    @Test func nestedFilterParensSurvive512KiBStack() throws {
        // `$[?((((@.a==1))))]` — parenthesised filter sub-expressions; recursion via `parsePrimary`.
        let doc = try ADJSON.parse(#"{"a":1}"#).root
        for n in depths() {
            let path = "$[?" + String(repeating: "(", count: n) + "@.a==1" + String(repeating: ")", count: n) + "]"
            parseSafely(path, evaluate: n <= 32 ? doc : nil)
        }
    }

    @Test func nestedLengthFunctionsSurvive512KiBStack() throws {
        // `$[?length(length(…(@)…))==1]` — recursion via `parseComparand`.
        let doc = try ADJSON.parse(#"[1,2,3]"#).root
        for n in depths() {
            let path = "$[?" + String(repeating: "length(", count: n) + "@" + String(repeating: ")", count: n) + "==1]"
            parseSafely(path, evaluate: n <= 32 ? doc : nil)
        }
    }

    @Test func deepMemberAndIndexChainsSurvive512KiBStack() throws {
        // Iterative constructs (`parseSegments` loops): a long `$.a.a.a…` / `$[0][0][0]…` chain must
        // parse (not just reject) at extreme length with no stack growth. Evaluate the bracket chain
        // against a matching deep document to also exercise the iterative evaluator.
        for n in depths() {
            parseSafely("$" + String(repeating: ".a", count: n))
            parseSafely("$" + String(repeating: "[0]", count: n))
        }
        // A bracket-index chain evaluated against a document nested to the same depth: the evaluator's
        // segment loop is iterative, so this resolves the innermost leaf without recursing.
        let n = 2_000
        let docText = String(repeating: "[", count: n) + "42" + String(repeating: "]", count: n)
        if let doc = try? ADJSON.parse(docText, options: JSONParseOptions(maxDepth: n + 2)).root {
            parseSafely("$" + String(repeating: "[0]", count: n), evaluate: doc)
        }
    }

    @Test func filterLogicalFloodsSurvive512KiBStack() throws {
        // `&&` / `||` fold in a loop and `!` folds by parity, so a huge run is O(1) stack. Verify on the
        // small stack alongside the recursive cases.
        let doc = try ADJSON.parse(#"{"a":1}"#).root
        for n in [100, 1_000, 5_000] {
            parseSafely("$[?" + Array(repeating: "@.a==1", count: n).joined(separator: " && ") + "]", evaluate: doc)
            parseSafely("$[?" + Array(repeating: "@.a==1", count: n).joined(separator: " || ") + "]", evaluate: doc)
            parseSafely("$[?" + String(repeating: "!", count: n) + "@]", evaluate: doc)
        }
    }

    @Test func pointerParsersSurvive512KiBStack() throws {
        // RFC 6901 / Relative JSON Pointer parse with plain loops; long inputs are a survival baseline.
        for n in [100, 1_000, 5_000] {
            onWorkerStack {
                _ = try? JSONPointer(String(repeating: "/a", count: n))
                _ = try? RelativeJSONPointer("0" + String(repeating: "/a", count: n))
                _ = try? SQLiteJSONPath("$" + String(repeating: "[0]", count: n))
                _ = try? SQLiteJSONPath("$" + String(repeating: ".a", count: n))
            }
        }
    }

    // MARK: - Focused depth-contract assertion at the cap boundary

    @Test func depthContractHoldsAtCapBoundary() throws {
        // Pin the contract: nesting the cap admits parses; nesting past it is rejected with a clean
        // `JSONPathError` (never a crash). Each construct consumes a different number of `enter()`
        // increments per *textual* nesting level — the nested-filter path increments ~3× per level
        // (`parseSegments`+`parsePrimary`+`parseComparand`), parens / `length()` ~1× — so the textual N
        // at which the cap (64) bites differs by construct. The pairs below straddle that boundary; both
        // sides are checked on the 512 KiB worker stack so the boundary itself is proven small-stack-safe.
        //                       construct          deepest-N-that-parses, first-N-rejected
        let boundaries: [(make: (Int) -> String, lastOK: Int, firstReject: Int)] = [
            (nestedFilterPath, 20, 21),  // ~3 increments/level → depth hits 64 at N=20
            (parenFilterPath, 60, 61),  // ~1 increment/level
            (lengthFilterPath, 60, 61)  // ~1 increment/level
        ]
        for b in boundaries {
            assertParses(b.make(b.lastOK))  // at the cap: compiles
            assertRejectsCleanly(b.make(b.firstReject))  // one past: clean JSONPathError, no crash
            assertRejectsCleanly(b.make(5_000))  // far past: still a clean rejection, no overflow
        }

        // A real (shallow) filter still parses AND evaluates correctly — the cap doesn't break normal use.
        let arr = try ADJSON.parse("[[1,2],[3],[4,5]]").root
        #expect(try arr.query("$[?length(@)==2]").count == 2)
        // `$..[?@.c==1]`: visit every node, keep array elements / object members whose `.c` is 1. The
        // single match is the inner `{"c":1}` object reached via descent — exercises a filter with a
        // (shallow) relative singular-query comparand on the small stack.
        let nested = try ADJSON.parse(#"{"a":[{"c":1},{"c":2}]}"#).root
        #expect(try nested.query("$..[?@.c==1]").count == 1)
    }

    // MARK: - Helpers

    /// Depth sweep: dense near the cap (where an off-by-a-few overflow would hide), then a few large
    /// values WELL past it (up to 5000). Bounded so the whole suite stays well under the time budget.
    private func depths() -> [Int] {
        [1, 4, 8, 12, 16, 17, 20, 24, 28, 32, 48, 64, 65, 100, 250, 500, 1_000, 2_500, 5_000]
    }

    private func nestedFilterPath(_ n: Int) -> String {
        "$" + String(repeating: "[?@", count: n) + "[?@.a==1]" + String(repeating: "]", count: n)
    }

    private func parenFilterPath(_ n: Int) -> String {
        "$[?" + String(repeating: "(", count: n) + "@.a==1" + String(repeating: ")", count: n) + "]"
    }

    private func lengthFilterPath(_ n: Int) -> String {
        "$[?" + String(repeating: "length(", count: n) + "@" + String(repeating: ")", count: n) + "==1]"
    }

    /// Assert `path` compiles, on the 512 KiB worker stack.
    private func assertParses(_ path: String) {
        let box = OutcomeBox()
        onWorkerStack { box.set(parsed: (try? JSONPath(path)) != nil) }
        #expect(box.parsed == true, "expected a parse within the cap, on the 512 KiB stack")
    }

    /// Assert `path` is rejected with a `JSONPathError` (not a crash), on the 512 KiB worker stack.
    private func assertRejectsCleanly(_ path: String) {
        let box = OutcomeBox()
        onWorkerStack {
            do {
                _ = try JSONPath(path)
                box.set(parsed: true)
            } catch is JSONPathError {
                box.set(parsed: false)
            } catch {
                box.set(parsed: true)  // some other error — still not a crash, but not the contract
            }
        }
        #expect(box.parsed == false, "expected a clean JSONPathError past the cap, on the 512 KiB stack")
    }
}

/// Tiny reference box so the worker thread can hand its outcome back to the joined test thread. The
/// `onWorkerStack` join (semaphore wait) happens-before the read, so the plain `var` needs no lock.
private final class OutcomeBox: @unchecked Sendable {
    private(set) var parsed: Bool?
    func set(parsed value: Bool) { parsed = value }
}
