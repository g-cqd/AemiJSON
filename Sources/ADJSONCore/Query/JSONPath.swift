// MARK: - AST

enum PathSegment: Sendable {
    case child([Selector])
    case descendant([Selector])
}

enum Selector: Sendable {
    case name(String)
    case wildcard
    case index(Int)
    case slice(start: Int?, end: Int?, step: Int)
    case filter(FilterExpr)
}

indirect enum FilterExpr: Sendable {
    case or([FilterExpr])
    case and([FilterExpr])
    case not(FilterExpr)
    case comparison(Comparand, CompOp, Comparand)
    case existence(RelQuery)
    case regex(Comparand, pattern: Comparand, anchored: Bool)  // match() / search()
}

enum CompOp: Sendable { case eq, ne, lt, le, gt, ge }

indirect enum Comparand: Sendable {
    case literal(Literal)
    case query(RelQuery)
    case length(Comparand)  // ValueType arg
    case count(RelQuery)  // NodesType arg
    case value(RelQuery)  // NodesType arg
}

enum Literal: Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null
}

struct RelQuery: Sendable {
    let fromRoot: Bool
    let segments: [PathSegment]

    /// RFC 9535 singular-query: a query producing at most one node — only single name/index
    /// selectors, no wildcards, slices, filters, multi-selectors, or descendant segments. Required
    /// of query operands in comparisons and of `length()`/`match()`/`search()` value arguments.
    var isSingular: Bool {
        segments.allSatisfy { seg in
            guard case .child(let sels) = seg, sels.count == 1 else { return false }
            switch sels[0] {
            case .name, .index: return true
            default: return false
            }
        }
    }
}

extension Comparand {
    /// RFC 9535 well-typedness: a `ValueType` operand is a literal, a singular query, or a
    /// value-returning function (`length`/`count`/`value`). Non-singular queries are `NodesType`
    /// and may only appear as `count`/`value` arguments or as a bare existence test.
    var isValueType: Bool {
        switch self {
        case .literal, .length, .count, .value: return true
        case .query(let q): return q.isSingular
        }
    }
}

/// RFC 9535 JSONPath, compiled once to an AST and reusable. `Sendable`.
///
/// Supported: root `$`, child & descendant (`..`) segments; name, wildcard `*`,
/// index (incl. negative), slice `start:end:step`, and filter `?(...)` selectors;
/// filter logic `&&`/`||`/`!` with parentheses; comparisons against literals and
/// singular relative/absolute queries; existence tests; the `length()`, `count()`,
/// `value()`, `match()`, and `search()` functions; and the RFC 9535 well-typedness rules
/// (singular-query operands, function argument types).
/// Not yet: full I-Regexp (RFC 9485) semantics — `match()`/`search()` use the Swift standard
/// regex engine, which differs from I-Regexp on a few edge cases (e.g. `.` vs line separators).
public struct JSONPath: Sendable {
    let segments: [PathSegment]

    public init(_ string: String) throws(JSONPathError) {
        var parser = JSONPathParser(string)
        segments = try parser.parseRoot()
    }

    /// The nodelist (in document order) selected from `root`.
    public func query(_ root: JSON) -> [JSON] {
        JSONPathEvaluator.evaluate(segments, start: root, root: root)
    }
}

extension JSON {
    /// Evaluate an RFC 9535 JSONPath against this value as the root.
    public func query(_ path: String) throws(JSONPathError) -> [JSON] {
        try JSONPath(path).query(self)
    }
}
