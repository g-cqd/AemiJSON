import ADTestKit
import Foundation
import Testing

@testable import ADJSON
@testable import ADJSONCore

private func doc(_ s: String) -> JSON { try! ADJSON.parse(s).root }

@Test func jsonPointerResolves() {
    let j = doc(#"{"a":{"b":[10,20,{"c~d":"x","e/f":"y"}]}}"#)
    // ADTestKit's typed asserts: six `#expect` expansions over the `@dynamicMemberLookup` JSON
    // chains tipped this body toward the type-check budget (same remedy as the slice tests below).
    expectEqual(j[pointer: "/a/b/0"].int, 10)
    expectEqual(j[pointer: "/a/b/2/c~0d"].string, "x")
    expectEqual(j[pointer: "/a/b/2/e~1f"].string, "y")
    expectTrue(j[pointer: ""].isObject)
    expectEqual(j[pointer: "/a/missing"].exists, false)
    expectEqual(j[pointer: "/a/b/9"].exists, false)
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

@Test func jsonPathSliceSemantics() throws {
    let a = doc("[0,1,2,3,4,5,6,7,8,9]")
    func slice(_ q: String) throws -> [Int] { try a.query(q).compactMap(\.int) }
    // ADTestKit's typed asserts: fifteen `#expect` macro expansions (each a throwing call compared
    // against an array literal) tipped this body past the 100ms type-check budget.
    // Positive step.
    expectEqual(try slice("$[1:4]"), [1, 2, 3])
    expectEqual(try slice("$[:3]"), [0, 1, 2])
    expectEqual(try slice("$[7:]"), [7, 8, 9])
    expectEqual(try slice("$[::2]"), [0, 2, 4, 6, 8])
    expectEqual(try slice("$[1:8:3]"), [1, 4, 7])
    expectEqual(try slice("$[-3:]"), [7, 8, 9])
    expectEqual(try slice("$[:-7]"), [0, 1, 2])
    expectEqual(try slice("$[100:200]"), [])  // out of range
    expectEqual(try slice("$[3:1]"), [])  // empty (lower >= upper)
    // Negative step (the forward-collect-then-reverse path).
    expectEqual(try slice("$[::-1]"), [9, 8, 7, 6, 5, 4, 3, 2, 1, 0])  // full reverse
    expectEqual(try slice("$[::-2]"), [9, 7, 5, 3, 1])
    expectEqual(try slice("$[5:1:-1]"), [5, 4, 3, 2])
    expectEqual(try slice("$[-1:-4:-1]"), [9, 8, 7])
    expectEqual(try slice("$[2:5:-1]"), [])  // descending range empty when start < end
    // Step 0 yields nothing (RFC 9535).
    expectEqual(try slice("$[1:5:0]"), [])
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

@Test func filterWithAbsoluteSubqueryCachesWithoutChangingResults() throws {
    // `$.threshold` is candidate-independent, so it is evaluated once and reused across candidates;
    // the memoization must not change which elements pass (50 < v).
    let j = doc(#"{"threshold":50,"items":[{"v":10},{"v":60},{"v":50},{"v":99},{"v":51}]}"#)
    #expect(try j.query("$.items[?($.threshold < @.v)].v").compactMap(\.int) == [60, 99, 51])
    // An absolute query ($.limit) compared against a function of the candidate is cached the same way.
    let k = doc(#"{"limit":2,"rows":[{"tags":["a"]},{"tags":["a","b","c"]},{"tags":["a","b"]}]}"#)
    #expect(try k.query("$.rows[?(length(@.tags) > $.limit)]").count == 1)
    // Mixed absolute + relative comparison still respects the relative side per candidate.
    #expect(try j.query("$.items[?(@.v == $.threshold)].v").compactMap(\.int) == [50])
}

@Test func jsonPathRootAndArrayRoot() throws {
    let a = doc("[1,2,3]")
    #expect(try a.query("$").count == 1)
    #expect(try a.query("$[*]").compactMap(\.int) == [1, 2, 3])
    #expect(try a.query("$[1]").compactMap(\.int) == [2])
    #expect(try a.query("$[-1]").compactMap(\.int) == [3])
}

@Test func jsonPathInvalidThrows() {
    expectThrows {
        try doc("{}").query("store.book")
    } where: { (_: JSONPathError) in
        true
    }  // missing $
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
    // recurse to a crash. The guard fires at `maxDepth` (64) — sized below the native-stack budget of
    // the heaviest (nested-filter) path on a 512 KB worker stack (see PathParserDepthTests) —
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
        #"$[?search(@.s, "(?:ab)+")]"#  // non-capturing group extension
    ]
    for q in unsafe { #expect(throws: JSONPathError.self) { try JSONPath(q) } }

    let safe = [
        #"$[?search(@.s, "[AB]")]"#,
        #"$[?search(@.s, "a.*b")]"#,
        #"$[?search(@.s, "(ab)+")]"#,
        #"$[?match(@.s, "a+b+")]"#
    ]
    for q in safe { #expect(throws: Never.self) { try JSONPath(q) } }
}
