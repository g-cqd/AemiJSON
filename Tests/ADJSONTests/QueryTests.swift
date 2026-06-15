import Foundation
import Testing

@testable import ADJSON

private func doc(_ s: String) -> JSON { try! ADJSON.parse(s).root }

@Test func jsonPointerResolves() {
    let j = doc(#"{"a":{"b":[10,20,{"c~d":"x","e/f":"y"}]}}"#)
    #expect(j[pointer: "/a/b/0"].int == 10)
    #expect(j[pointer: "/a/b/2/c~0d"].string == "x")
    #expect(j[pointer: "/a/b/2/e~1f"].string == "y")
    #expect(j[pointer: ""].isObject)
    #expect(j[pointer: "/a/missing"].exists == false)
    #expect(j[pointer: "/a/b/9"].exists == false)
}

@Test func deepDescendantQueryDoesNotOverflow() throws {
    // `$..x` over a 5k-deep object exercises the now-iterative `descend`; recursive descent
    // would overflow the stack at this depth.
    let depth = 5_000
    let nested = String(repeating: #"{"x":"#, count: depth) + "1" + String(repeating: "}", count: depth)
    let root = try ADJSON.parse(nested, options: JSONParseOptions(maxDepth: depth + 1)).root
    #expect(try root.query("$..x").count == depth)
}

private let store = doc(
    #"""
    {"store":{"book":[{"title":"A","price":5,"tags":["x"]},{"title":"B","price":15},{"title":"C","price":8,"author":"Z"}],"bicycle":{"price":100}}}
    """#)

@Test func jsonPathStructural() throws {
    #expect(try store.query("$.store.book[0].title").compactMap(\.string) == ["A"])
    #expect(try store.query("$.store.book[*].title").compactMap(\.string) == ["A", "B", "C"])
    #expect(try store.query("$.store.book[-1].title").compactMap(\.string) == ["C"])
    #expect(try store.query("$.store.book[0:2].title").compactMap(\.string) == ["A", "B"])
    #expect(try store.query("$..price").compactMap(\.double).sorted() == [5, 8, 15, 100])
    #expect(try store.query("$['store']['book'][2]['author']").compactMap(\.string) == ["Z"])
}

@Test func jsonPathFilters() throws {
    #expect(try store.query("$.store.book[?(@.price < 10)].title").compactMap(\.string) == ["A", "C"])
    #expect(try store.query("$.store.book[?(@.price >= 8 && @.price <= 15)].title").compactMap(\.string) == ["B", "C"])
    #expect(try store.query("$.store.book[?(@.author)].title").compactMap(\.string) == ["C"])
    #expect(try store.query("$.store.book[?(@.tags)].title").compactMap(\.string) == ["A"])
    #expect(try store.query(#"$.store.book[?(@.title == "B")].price"#).compactMap(\.int) == [15])
    #expect(try store.query("$.store.book[?(length(@.title) == 1)].price").count == 3)
    #expect(try store.query(#"$.store.book[?(search(@.title, "[AB]"))].title"#).compactMap(\.string) == ["A", "B"])
    #expect(try store.query("$.store.book[?(!(@.price > 10))].title").compactMap(\.string) == ["A", "C"])
}

@Test func jsonPathRootAndArrayRoot() throws {
    let a = doc("[1,2,3]")
    #expect(try a.query("$").count == 1)
    #expect(try a.query("$[*]").compactMap(\.int) == [1, 2, 3])
    #expect(try a.query("$[1]").compactMap(\.int) == [2])
    #expect(try a.query("$[-1]").compactMap(\.int) == [3])
}

@Test func jsonPathInvalidThrows() {
    #expect(throws: (any Error).self) { try doc("{}").query("store.book") }  // missing $
}

@Test func filterNotFloodParsesWithoutStackOverflow() throws {
    // A 200k-long run of `!` would overflow a per-`!`-recursive filter parser; the iterative
    // parity count must handle it in O(1) stack. `!!x ≡ x`, so an even count is a plain existence
    // test and an odd count is a single negation.
    let arr = try ADJSON.parse("[1,2,3]").root
    let evenBangs = String(repeating: "!", count: 200_000)
    #expect(try JSONPath("$[?\(evenBangs)@]").query(arr).count == 3)  // even → @ exists for all
    #expect(try JSONPath("$[?\(evenBangs)!@]").query(arr).count == 0)  // odd → !@ false for all
}

@Test func deeplyNestedFilterStructureIsRejectedNotOverflowed() {
    // The filter parser's only growing recursion is structural (parens / nested bracket-filters);
    // the `enter()`/maxDepth guard must reject pathological nesting with an error rather than
    // recurse to a crash. The guard fires at `maxDepth` (64) — far below the per-level stack budget —
    // regardless of total length. (`&&`/`||`/`!` runs are already iterative, covered elsewhere.)
    let deepParens = "$[?" + String(repeating: "(", count: 1_000) + "@" + String(repeating: ")", count: 1_000) + "]"
    #expect(throws: JSONPathError.self) { try JSONPath(deepParens) }
    let deepFilters = "$" + String(repeating: "[?@", count: 1_000) + "1" + String(repeating: "]", count: 1_000)
    #expect(throws: JSONPathError.self) { try JSONPath(deepFilters) }
}

@Test func wildcardAndDescendantVisitDuplicateKeysInOrder() throws {
    // Under the default last-value-wins parse the tape retains every member, so a wildcard must
    // visit all of them in document order — `objectValue.values` would collapse the duplicate `a`
    // and randomize order.
    let j = try ADJSON.parse(#"{"a":1,"a":2,"b":3}"#).root
    #expect(try j.query("$[*]").compactMap(\.int) == [1, 2, 3])
    #expect(try j.query("$.*").compactMap(\.int) == [1, 2, 3])
    #expect(try j.query("$..*").compactMap(\.int) == [1, 2, 3])
}

@Test func regexPatternSafetyAtParseTime() {
    // Catastrophic-backtracking shapes and non-I-Regexp constructs are rejected when the path is
    // compiled — before any JSON is matched — so a literal pattern can never reach the backtracking
    // engine in an unsafe form.
    let unsafe = [
        #"$[?match(@.s, "(a+)+$")]"#,  // nested unbounded quantifier
        #"$[?search(@.s, "(a*)*")]"#,  // nested unbounded quantifier
        #"$[?match(@.s, "\\1")]"#,  // backreference (pattern is \1)
        #"$[?match(@.s, "(?=a)")]"#,  // lookahead
        #"$[?search(@.s, "(?:ab)+")]"#,  // non-capturing group extension
    ]
    for q in unsafe { #expect(throws: JSONPathError.self) { try JSONPath(q) } }

    let safe = [
        #"$[?search(@.s, "[AB]")]"#,
        #"$[?search(@.s, "a.*b")]"#,
        #"$[?search(@.s, "(ab)+")]"#,
        #"$[?match(@.s, "a+b+")]"#,
    ]
    for q in safe { #expect(throws: Never.self) { try JSONPath(q) } }
}
