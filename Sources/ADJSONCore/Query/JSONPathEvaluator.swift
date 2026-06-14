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
        // Iterative preorder DFS: children are pushed reversed so they pop in document order,
        // matching the former recursion exactly — but with no call-stack growth, so a
        // descendant query (`..`) over a deeply nested document can't overflow the stack.
        var stack = [node]
        while let n = stack.popLast() {
            visit(n)
            if n.isArray {
                for e in n.arrayValue.reversed() { stack.append(e) }
            } else if n.isObject {
                for v in n.objectValue.values.reversed() { stack.append(v) }
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
            if node.isArray {
                out.append(contentsOf: node.arrayValue)
            } else if node.isObject {
                out.append(contentsOf: node.objectValue.values)
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
            if node.isArray {
                for e in node.arrayValue where evalFilter(expr, current: e, root: root) { out.append(e) }
            } else if node.isObject {
                for v in node.objectValue.values where evalFilter(expr, current: v, root: root) { out.append(v) }
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

    static func evalFilter(_ e: FilterExpr, current: JSON, root: JSON) -> Bool {
        switch e {
        case .or(let xs): return xs.contains { evalFilter($0, current: current, root: root) }
        case .and(let xs): return xs.allSatisfy { evalFilter($0, current: current, root: root) }
        case .not(let x): return !evalFilter(x, current: current, root: root)
        case .existence(let q): return !evalQuery(q, current: current, root: root).isEmpty
        case .comparison(let l, let op, let r):
            return compare(
                evalComparand(l, current: current, root: root), op, evalComparand(r, current: current, root: root))
        case .regex(let s, let p, let anchored):
            return evalRegex(s, p, anchored, current: current, root: root)
        }
    }

    static func evalQuery(_ q: RelQuery, current: JSON, root: JSON) -> [JSON] {
        evaluate(q.segments, start: q.fromRoot ? root : current, root: root)
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

    static func evalComparand(_ c: Comparand, current: JSON, root: JSON) -> QueryValue {
        switch c {
        case .literal(let l):
            switch l {
            case .number(let n): return .number(n)
            case .string(let s): return .string(s)
            case .bool(let b): return .bool(b)
            case .null: return .null
            }
        case .query(let q):
            let r = evalQuery(q, current: current, root: root)
            return r.count == 1 ? coerce(r[0]) : .nothing
        case .length(let arg):
            switch evalComparand(arg, current: current, root: root) {
            case .string(let s): return .number(Double(s.unicodeScalars.count))
            case .structural(let j) where j.isArray || j.isObject: return .number(Double(j.count))
            default: return .nothing
            }
        case .count(let q):
            return .number(Double(evalQuery(q, current: current, root: root).count))
        case .value(let q):
            let r = evalQuery(q, current: current, root: root)
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

    static func evalRegex(_ sc: Comparand, _ pc: Comparand, _ anchored: Bool, current: JSON, root: JSON) -> Bool {
        guard case let .string(s) = evalComparand(sc, current: current, root: root),
            case let .string(pat) = evalComparand(pc, current: current, root: root),
            let re = try? Regex(iRegexpToSwift(pat))
        else { return false }
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
}
