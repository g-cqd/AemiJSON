import Foundation

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

enum Comparand: Sendable {
    case literal(Literal)
    case query(RelQuery)
    case length(RelQuery)
    case count(RelQuery)
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
}

/// RFC 9535 JSONPath, compiled once to an AST and reusable. `Sendable`.
///
/// Supported: root `$`, child & descendant (`..`) segments; name, wildcard `*`,
/// index (incl. negative), slice `start:end:step`, and filter `?(...)` selectors;
/// filter logic `&&`/`||`/`!` with parentheses; comparisons against literals and
/// relative/absolute queries; existence tests; and `length()`, `count()`,
/// `match()`, `search()` functions.
/// Not yet: `value()`, full I-Regexp semantics, the formal well-typedness checker.
public struct JSONPath: Sendable {
    let segments: [PathSegment]

    public init(_ string: String) throws {
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
    public func query(_ path: String) throws -> [JSON] {
        try JSONPath(path).query(self)
    }
}
