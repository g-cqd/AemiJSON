import AemiRegex

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
                    node.forEachElement { e in
                        if evalFilter(expr, current: e, root: root, cache: cache) { out.append(e) }
                    }
                } else if node.isObject {
                    node.forEachMember { _, v in
                        if evalFilter(expr, current: v, root: root, cache: cache) { out.append(v) }
                    }
                }
        }
    }

    static func appendSlice(_ node: JSON, _ start: Int?, _ end: Int?, _ step: Int, _ out: inout [JSON]) {
        // Single-pass tape walk (stops at the slice bound) instead of materializing `node.arrayValue`.
        node.appendSlice(start: start, end: end, step: step, into: &out)
    }

    // MARK: - Filters

    // Recurses over the filter AST for the nested `&&`/`||`/`!` structure (the leaf tests —
    // existence, comparison, regex — bottom out into the iterative `evaluate`). The AST is produced
    // by `JSONPathParser`, whose `enter()`/`maxDepth` guard caps logical nesting, so this recursion
    // is bounded (≤ `JSONPathParser.maxDepth`). The local `depth` guard self-bounds it too, so it
    // never depends on that far-away invariant: an over-deep AST conservatively matches nothing.
    static func evalFilter(
        _ e: FilterExpr, current: JSON, root: JSON, cache: FilterCache, depth: Int = 0
    ) -> Bool {
        guard depth <= JSONPathParser.maxDepth else { return false }
        switch e {
            case .or(let xs):
                return xs.contains { evalFilter($0, current: current, root: root, cache: cache, depth: depth + 1) }
            case .and(let xs):
                return xs.allSatisfy { evalFilter($0, current: current, root: root, cache: cache, depth: depth + 1) }
            case .not(let x): return !evalFilter(x, current: current, root: root, cache: cache, depth: depth + 1)
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
        if case .number(let a) = l, case .number(let b) = r { return a < b }
        if case .string(let a) = l, case .string(let b) = r { return a < b }
        return false
    }

    static func valueEqual(_ l: QueryValue, _ r: QueryValue) -> Bool {
        switch (l, r) {
            case (.nothing, .nothing): return true
            case (.null, .null): return true
            case (.bool(let a), .bool(let b)): return a == b
            case (.number(let a), .number(let b)): return a == b
            case (.string(let a), .string(let b)): return a == b
            case (.structural(let a), .structural(let b)): return JSONValueSemantics.areEqual(a, b)
            default: return false
        }
    }

    static func evalRegex(
        _ sc: Comparand, _ pattern: RegexOperand, _ anchored: Bool, current: JSON, root: JSON, cache: FilterCache
    )
        -> Bool
    {
        guard case .string(let s) = evalComparand(sc, current: current, root: root, cache: cache) else { return false }
        let re: Pattern
        switch pattern {
            case .compiled(let compiled):
                re = compiled  // literal pattern: checked + compiled once at parse time
            case .dynamic(let pc):
                // A pattern sourced from the (untrusted) JSON document is checked against the I-Regexp grammar
                // here; a malformed pattern simply doesn't match (evaluation can't throw).
                guard case .string(let pat) = evalComparand(pc, current: current, root: root, cache: cache),
                    let compiled = try? Pattern(
                        pat, syntax: .iRegexpWithAnchors, matching: anchored ? .wholeString : .search)
                else { return false }
                re = compiled
        }
        // RFC 9535: `match()` is a whole-string match and `search()` finds a substring; the pattern was
        // compiled in the matching mode that says which.
        return re.isMatch(in: s)
    }
}
