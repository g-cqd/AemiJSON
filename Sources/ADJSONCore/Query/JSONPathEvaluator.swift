// Memoizes absolute (`$`-rooted) sub-query results within a single filter application. Such a query
// is candidate-independent — its nodelist depends only on the document root — so evaluating it once
// and reusing it across every candidate turns an O(candidates × subquery) filter into
// O(candidates + subquery). Relative (`@`) queries are never cached (they vary per candidate). The
// cache is local to one synchronous evaluation, so it needs no synchronization.
final class FilterCache {
    var absolute: [Int: [JSON]] = [:]
}

enum JSONPathEvaluator {
    static func evaluate(_ segments: [PathSegment], start: JSON, root: JSON) -> [JSON] {
        var nodes = [start]
        for seg in segments {
            var next: [JSON] = []
            switch seg {
            case .child(let sels):
                for n in nodes { for s in sels { applySelector(s, to: n, root: root, into: &next) } }
            case .descendant(let sels):
                for n in nodes {
                    descend(n) { d in for s in sels { applySelector(s, to: d, root: root, into: &next) } }
                }
            }
            nodes = next
        }
        return nodes
    }

    static func descend(_ node: JSON, _ visit: (JSON) -> Void) {
        // Iterative preorder DFS: children are pushed reversed so they pop in document order, with no
        // call-stack growth — so a descendant query (`..`) over a deeply nested document can't
        // overflow the stack.
        var stack = [node]
        var kids: [JSON] = []
        while let n = stack.popLast() {
            visit(n)
            // Buffer children in document order (`forEachMember` keeps every member — including
            // duplicate keys — unlike `objectValue`, which collapses them into a dictionary), then
            // push reversed so they pop back in document order.
            if n.isArray {
                kids.removeAll(keepingCapacity: true)
                n.forEachElement { kids.append($0) }
                for e in kids.reversed() { stack.append(e) }
            } else if n.isObject {
                kids.removeAll(keepingCapacity: true)
                n.forEachMember { _, v in kids.append(v) }
                for v in kids.reversed() { stack.append(v) }
            }
        }
    }

    static func applySelector(_ sel: Selector, to node: JSON, root: JSON, into out: inout [JSON]) {
        switch sel {
        case .name(let n):
            if node.isObject {
                let v = node[n]
                if v.exists { out.append(v) }
            }
        case .wildcard:
            // RFC 9535: visit every array element / object member in document order. The lazy
            // walkers append directly (no intermediate `[JSON]`/dictionary) and preserve duplicate
            // keys, which `objectValue.values` would collapse and reorder.
            if node.isArray {
                node.forEachElement { out.append($0) }
            } else if node.isObject {
                node.forEachMember { _, v in out.append(v) }
            }
        case .index(let idx):
            if node.isArray {
                let c = node.count
                let real = idx < 0 ? c + idx : idx
                if real >= 0, real < c { out.append(node[index: real]) }
            }
        case .slice(let start, let end, let step):
            if node.isArray { appendSlice(node, start, end, step, &out) }
        case .filter(let expr):
            // One cache per filter application: any absolute (`$`) sub-query inside `expr` yields the
            // same nodelist for every candidate, so it is computed once and reused (see `FilterCache`).
            let cache = FilterCache()
            if node.isArray {
                node.forEachElement { e in if evalFilter(expr, current: e, root: root, cache: cache) { out.append(e) } }
            } else if node.isObject {
                node.forEachMember { _, v in if evalFilter(expr, current: v, root: root, cache: cache) { out.append(v) }
                }
            }
        }
    }

    static func appendSlice(_ node: JSON, _ start: Int?, _ end: Int?, _ step: Int, _ out: inout [JSON]) {
        let len = node.count
        if step == 0 || len == 0 { return }
        let elems = node.arrayValue
        func normalize(_ v: Int) -> Int { v >= 0 ? v : len + v }

        if step > 0 {
            let s = start.map(normalize) ?? 0
            let e = end.map(normalize) ?? len
            let lower = Swift.min(Swift.max(s, 0), len)
            let upper = Swift.min(Swift.max(e, 0), len)
            var i = lower
            while i < upper {
                out.append(elems[i])
                i += step
            }
        } else {
            let s = start.map(normalize) ?? (len - 1)
            let e = end.map(normalize) ?? (-len - 1)
            let upper = Swift.min(Swift.max(s, -1), len - 1)
            let lower = Swift.min(Swift.max(e, -1), len - 1)
            var i = upper
            while i > lower {
                out.append(elems[i])
                i += step
            }
        }
    }

    // MARK: - Filters

    // Recurses over the filter AST for the nested `&&`/`||`/`!` structure (the leaf tests —
    // existence, comparison, regex — bottom out into the iterative `evaluate`). The AST is produced
    // by `JSONPathParser`, whose `enter()`/`maxDepth` guard caps logical nesting, so this recursion
    // is bounded (≤ `JSONPathParser.maxDepth`) and a crafted query can't drive it to overflow.
    static func evalFilter(_ e: FilterExpr, current: JSON, root: JSON, cache: FilterCache) -> Bool {
        switch e {
        case .or(let xs): return xs.contains { evalFilter($0, current: current, root: root, cache: cache) }
        case .and(let xs): return xs.allSatisfy { evalFilter($0, current: current, root: root, cache: cache) }
        case .not(let x): return !evalFilter(x, current: current, root: root, cache: cache)
        case .existence(let q): return !evalQuery(q, current: current, root: root, cache: cache).isEmpty
        case .comparison(let l, let op, let r):
            return compare(
                evalComparand(l, current: current, root: root, cache: cache), op,
                evalComparand(r, current: current, root: root, cache: cache))
        case .regex(let s, let p, let anchored):
            return evalRegex(s, p, anchored, current: current, root: root, cache: cache)
        }
    }

    static func evalQuery(_ q: RelQuery, current: JSON, root: JSON, cache: FilterCache) -> [JSON] {
        // A relative (`@`) query depends on the candidate, so it is always evaluated fresh. An
        // absolute (`$`) query depends only on root, so it is memoized once per filter application.
        guard q.fromRoot else { return evaluate(q.segments, start: current, root: root) }
        if let hit = cache.absolute[q.id] { return hit }
        let result = evaluate(q.segments, start: root, root: root)
        cache.absolute[q.id] = result
        return result
    }

    enum QueryValue {
        case nothing, null
        case bool(Bool)
        case number(Double)
        case string(String)
        case structural(JSON)
    }

    static func coerce(_ j: JSON) -> QueryValue {
        if j.isNull { return .null }
        if let b = j.bool { return .bool(b) }
        if j.isNumberKind, let d = j.double { return .number(d) }
        if let s = j.string { return .string(s) }
        return .structural(j)
    }

    static func evalComparand(_ c: Comparand, current: JSON, root: JSON, cache: FilterCache) -> QueryValue {
        switch c {
        case .literal(let l):
            switch l {
            case .number(let n): return .number(n)
            case .string(let s): return .string(s)
            case .bool(let b): return .bool(b)
            case .null: return .null
            }
        case .query(let q):
            let r = evalQuery(q, current: current, root: root, cache: cache)
            return r.count == 1 ? coerce(r[0]) : .nothing
        case .length(let arg):
            switch evalComparand(arg, current: current, root: root, cache: cache) {
            case .string(let s): return .number(Double(s.unicodeScalars.count))
            case .structural(let j) where j.isArray || j.isObject: return .number(Double(j.count))
            default: return .nothing
            }
        case .count(let q):
            return .number(Double(evalQuery(q, current: current, root: root, cache: cache).count))
        case .value(let q):
            let r = evalQuery(q, current: current, root: root, cache: cache)
            return r.count == 1 ? coerce(r[0]) : .nothing
        }
    }

    static func compare(_ l: QueryValue, _ op: CompOp, _ r: QueryValue) -> Bool {
        switch op {
        case .eq: return valueEqual(l, r)
        case .ne: return !valueEqual(l, r)
        case .lt: return lessThan(l, r)
        case .le: return lessThan(l, r) || valueEqual(l, r)
        case .gt: return lessThan(r, l)
        case .ge: return lessThan(r, l) || valueEqual(l, r)
        }
    }

    // RFC 9535 §2.3.5.2.2: `<` is defined only for two numbers or two strings; every other operand
    // pairing (booleans, null, mismatched types, missing/`Nothing`) is unordered and compares false.
    // `<=`/`>=` therefore reduce to `< || ==` and `> || ==`.
    static func lessThan(_ l: QueryValue, _ r: QueryValue) -> Bool {
        if case let .number(a) = l, case let .number(b) = r { return a < b }
        if case let .string(a) = l, case let .string(b) = r { return a < b }
        return false
    }

    static func valueEqual(_ l: QueryValue, _ r: QueryValue) -> Bool {
        switch (l, r) {
        case (.nothing, .nothing): return true
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.structural(a), .structural(b)): return jsonSemanticEqual(a, b)
        default: return false
        }
    }

    static func evalRegex(
        _ sc: Comparand, _ pattern: RegexOperand, _ anchored: Bool, current: JSON, root: JSON, cache: FilterCache
    )
        -> Bool
    {
        guard case let .string(s) = evalComparand(sc, current: current, root: root, cache: cache) else { return false }
        let re: Regex<AnyRegexOutput>
        switch pattern {
        case .compiled(let c):
            re = c.regex  // literal pattern: validated + compiled once at parse time
        case .dynamic(let pc):
            // A pattern sourced from the (untrusted) JSON document must be re-validated against the
            // I-Regexp safe subset before it reaches the backtracking engine; an unsafe or malformed
            // pattern simply doesn't match (eval can't throw).
            guard case let .string(pat) = evalComparand(pc, current: current, root: root, cache: cache),
                iRegexpRejectionReason(pat) == nil,
                let compiled = try? Regex(iRegexpToSwift(pat))
            else { return false }
            re = compiled
        }
        // RFC 9535: `match()` is a full (anchored) match; `search()` finds a substring. Swift's
        // standard-library `Regex` (not Foundation) provides both via `wholeMatch` / `firstMatch`.
        // `try?` flattens the optional `Match`, so a `nil` result already means "no match".
        if anchored {
            return (try? re.wholeMatch(in: s)) != nil
        }
        return (try? re.firstMatch(in: s)) != nil
    }

    // RFC 9485 I-Regexp `.` matches any character except U+000A (LF). Swift's `Regex` `.` also
    // excludes the other line separators (CR, U+2028, U+2029, U+0085…), so rewrite each unescaped,
    // outside-a-class `.` to `[^\n]` to recover I-Regexp semantics. Other I-Regexp constructs map to
    // the Swift engine directly.
    static func iRegexpToSwift(_ pattern: String) -> String {
        var out = ""
        out.reserveCapacity(pattern.count + 4)
        var inClass = false
        var escaped = false
        for c in pattern {
            if escaped {
                out.append(c)
                escaped = false
            } else if c == "\\" {
                out.append(c)
                escaped = true
            } else if c == "[" {
                inClass = true
                out.append(c)
            } else if c == "]" {
                inClass = false
                out.append(c)
            } else if c == "." && !inClass {
                out.append("[^\n]")
            } else {
                out.append(c)
            }
        }
        return out
    }

    // RFC 9485 I-Regexp is a *regular* (backtrack-free) language, so a conforming pattern can be
    // matched in linear time. Swift's `Regex`, however, is a backtracking engine, so the trust
    // boundary for `match()`/`search()` is: (a) reject backreferences and (b) lookaround/group
    // extensions — neither is valid I-Regexp, and both let the engine run super-linearly; and
    // (c) reject an unbounded quantifier (`*`/`+`/`{n,}`) wrapped around a group that itself
    // contains one (`(a+)+`), the classic catastrophic-backtracking shape. Returns a human-readable
    // reason when the pattern is outside this safe subset, or `nil` when it is acceptable.
    static func iRegexpRejectionReason(_ pattern: String) -> String? {
        let s = Array(pattern.unicodeScalars)
        var i = 0
        var inClass = false
        var classStart = false  // just inside `[`/`[^`, where a leading `]` is literal
        var groupHasUnbounded = [false]  // per open group; index 0 is the top level
        func isDigit(_ u: Unicode.Scalar) -> Bool { (0x30...0x39).contains(u.value) }

        // If a quantifier begins at `i`, consume it and report whether it is unbounded.
        func takeQuantifier() -> (present: Bool, unbounded: Bool) {
            guard i < s.count else { return (false, false) }
            switch s[i] {
            case "*", "+":
                i += 1
                return (true, true)
            case "?":
                i += 1
                return (true, false)
            case "{":
                var j = i + 1
                let lowStart = j
                while j < s.count, isDigit(s[j]) { j += 1 }
                guard j > lowStart else { return (false, false) }  // `{` not starting a quantity
                var unbounded = false
                if j < s.count, s[j] == "," {
                    j += 1
                    let highStart = j
                    while j < s.count, isDigit(s[j]) { j += 1 }
                    if j == highStart { unbounded = true }  // `{n,}` — no upper bound
                }
                guard j < s.count, s[j] == "}" else { return (false, false) }
                i = j + 1
                return (true, unbounded)
            default:
                return (false, false)
            }
        }

        while i < s.count {
            let c = s[i]
            if c == "\\" {
                guard i + 1 < s.count else { return "trailing backslash in pattern" }
                if !inClass, isDigit(s[i + 1]) { return "backreferences are not allowed in match()/search()" }
                i += 2
                classStart = false
                continue
            }
            if inClass {
                if c == "]" && !classStart { inClass = false } else { classStart = false }
                i += 1
                continue
            }
            switch c {
            case "[":
                inClass = true
                classStart = true
                if i + 1 < s.count, s[i + 1] == "^" { i += 1 }
                i += 1
            case "(":
                if i + 1 < s.count, s[i + 1] == "?" {
                    return "lookaround / group extensions are not allowed in match()/search()"
                }
                groupHasUnbounded.append(false)
                i += 1
            case ")":
                let inner = groupHasUnbounded.count > 1 ? groupHasUnbounded.removeLast() : false
                i += 1
                let q = takeQuantifier()
                if q.present, q.unbounded {
                    if inner { return "nested unbounded quantifier may cause catastrophic backtracking" }
                    groupHasUnbounded[groupHasUnbounded.count - 1] = true
                }
            case "*", "+":
                groupHasUnbounded[groupHasUnbounded.count - 1] = true
                i += 1
            case "{":
                let q = takeQuantifier()
                if q.present {
                    if q.unbounded { groupHasUnbounded[groupHasUnbounded.count - 1] = true }
                } else {
                    i += 1  // a literal `{`
                }
            default:
                i += 1
            }
        }
        return nil
    }
}
