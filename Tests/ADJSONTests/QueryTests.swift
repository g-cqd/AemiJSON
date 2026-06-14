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
