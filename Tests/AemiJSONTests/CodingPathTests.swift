import Foundation
import Testing

@testable import AemiJSON

// Roadmap 0005. A decoding or encoding error carries the coding path Foundation gives: the path from the root to the value at fault, with
// array positions as integer keys and, under a key strategy, the type's own keys. Every case decodes or encodes with both and compares.

private struct P: Codable { var n: Int }
private struct U: Codable {
    var id: Int
    var p: P
    var tags: [Int]
}
private struct E: Encodable { var v: [Double] }
private struct Snake: Codable { var userName: Int }

/// Decodes `base` through `superDecoder(forKey:)`.
private struct WithSuper: Decodable {
    enum K: String, CodingKey { case base }
    let base: P
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        base = try P(from: c.superDecoder(forKey: .base))
    }
}

/// Reads `p.n` through a nested container, then rejects a negative `n` with an error of its own.
private struct Nested: Decodable {
    enum K: String, CodingKey { case p }
    enum PK: String, CodingKey { case n }
    let n: Int
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let p = try c.nestedContainer(keyedBy: PK.self, forKey: .p)
        n = try p.decode(Int.self, forKey: .n)
        guard n >= 0 else { throw DecodingError.dataCorruptedError(forKey: .n, in: p, debugDescription: "negative") }
    }
}

/// Reads a list through a nested unkeyed container, and a pair inside it through a nested keyed one.
private struct Rows: Decodable {
    enum K: String, CodingKey { case rows }
    let total: Int
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        var rows = try c.nestedUnkeyedContainer(forKey: .rows)
        var total = 0
        while !rows.isAtEnd {
            let row = try rows.nestedContainer(keyedBy: P.CodingKeys.self)
            total += try row.decode(Int.self, forKey: .n)
        }
        self.total = total
    }
}

extension P {
    enum CodingKeys: String, CodingKey { case n }
}

/// Writes `meta.x` through a nested container, and a list through a nested unkeyed one.
private struct Meta: Encodable {
    enum K: String, CodingKey { case meta, list }
    enum MK: String, CodingKey { case x }
    let x: Double
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        var list = c.nestedUnkeyedContainer(forKey: .list)
        try list.encode(1)
        try list.encode(P(n: 2))
        var meta = c.nestedContainer(keyedBy: MK.self, forKey: .meta)
        try meta.encode(x, forKey: .x)
    }
}

private struct InList: Encodable {
    let values: [Double]
    func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        var inner = c.nestedUnkeyedContainer()
        for v in values { try inner.encode(v) }
    }
}

private func path(_ error: any Error) -> [String] {
    let context: (any Sequence<any CodingKey>)?
    switch error {
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c),
            DecodingError.keyNotFound(_, let c),
            DecodingError.dataCorrupted(let c):
            context = c.codingPath
        case EncodingError.invalidValue(_, let c):
            context = c.codingPath
        default:
            context = nil
    }
    guard let context else { return ["not a coding error: \(error)"] }
    return context.map { $0.intValue.map(String.init) ?? $0.stringValue }
}

private func decodePaths<T: Decodable>(
    _ type: T.Type, _ json: String, snake: Bool = false
) -> (mine: [String], theirs: [String]) {
    let data = Data(json.utf8)
    var mine = AemiJSON.JSONDecoder()
    let theirs = Foundation.JSONDecoder()
    if snake {
        mine.keyDecodingStrategy = .convertFromSnakeCase
        theirs.keyDecodingStrategy = .convertFromSnakeCase
    }
    let a: [String]
    let b: [String]
    do {
        _ = try mine.decode(type, from: data)
        a = ["no error"]
    } catch { a = path(error) }
    do {
        _ = try theirs.decode(type, from: data)
        b = ["no error"]
    } catch { b = path(error) }
    return (a, b)
}

private func encodePaths<T: Encodable>(_ value: T) -> (mine: [String], theirs: [String]) {
    let a: [String]
    let b: [String]
    do {
        _ = try AemiJSON.JSONEncoder().encode(value)
        a = ["no error"]
    } catch { a = path(error) }
    do {
        _ = try Foundation.JSONEncoder().encode(value)
        b = ["no error"]
    } catch { b = path(error) }
    return (a, b)
}

@Suite struct CodingPathTests {
    @Test func aWrongTypeInANestedObject() {
        let r = decodePaths([U].self, #"[{"id":1,"p":{"n":1},"tags":[1]},{"id":2,"p":{"n":"x"},"tags":[1]}]"#)
        #expect(r.theirs == ["1", "p", "n"])
        #expect(r.mine == r.theirs)
    }

    @Test func aWrongTypeInANestedArray() {
        let r = decodePaths([U].self, #"[{"id":1,"p":{"n":1},"tags":[1,"y"]}]"#)
        #expect(r.theirs == ["0", "tags", "1"])
        #expect(r.mine == r.theirs)
    }

    @Test func aMissingKeyInANestedObject() {
        let r = decodePaths([U].self, #"[{"id":1,"p":{},"tags":[]}]"#)
        #expect(r.theirs == ["0", "p"])
        #expect(r.mine == r.theirs)
    }

    @Test func aWrongTypeInAnArrayOfArrays() {
        let r = decodePaths([[Int]].self, #"[[1],[2,"x"]]"#)
        #expect(r.mine == r.theirs)
    }

    @Test func aWrongTypeInADictionary() {
        let r = decodePaths([String: [Int]].self, #"{"a":[1],"b":[2,"x"]}"#)
        #expect(r.mine == r.theirs)
    }

    @Test func aKeyStrategyReportsTheTypesOwnKey() {
        let r = decodePaths([Snake].self, #"[{"user_name":1},{"user_name":"x"}]"#, snake: true)
        #expect(r.theirs == ["1", "userName"])
        #expect(r.mine == r.theirs)
    }

    @Test func aSuperDecoderKeepsItsKey() {
        let r = decodePaths([WithSuper].self, #"[{"base":{"n":"x"}}]"#)
        #expect(r.theirs == ["0", "base", "n"])
        #expect(r.mine == r.theirs)
    }

    @Test func aNestedContainerAndAnErrorOfTheTypesOwn() {
        let wrongType = decodePaths([Nested].self, #"[{"p":{"n":1}},{"p":{"n":"x"}}]"#)
        #expect(wrongType.mine == wrongType.theirs)
        let ownError = decodePaths([String: Nested].self, #"{"a":{"p":{"n":-1}}}"#)
        #expect(ownError.theirs == ["a", "p", "n"])
        #expect(ownError.mine == ownError.theirs)
    }

    @Test func nestedUnkeyedAndKeyedContainers() {
        let r = decodePaths([Rows].self, #"[{"rows":[{"n":1},{"n":"x"}]}]"#)
        #expect(r.mine == r.theirs)
    }

    @Test func encodingANaNInANestedArray() {
        let r = encodePaths([E(v: [1, .nan])])
        #expect(r.theirs == ["0", "v"])
        #expect(r.mine == r.theirs)
    }

    // Foundation's encoder drops a nested container's own key or position (`["a", "0", "x"]` and `["b", "1"]` on this toolchain) where its
    // decoder keeps them; AemiJSON keeps them on both sides.
    @Test func encodingANaNThroughNestedContainers() {
        let keyed = encodePaths(["a": [Meta(x: .infinity)]])
        #expect(keyed.theirs == ["a", "0", "x"])
        #expect(keyed.mine == ["a", "0", "meta", "x"])
        let unkeyed = encodePaths(["b": InList(values: [1, .nan])])
        #expect(unkeyed.theirs == ["b", "1"])
        #expect(unkeyed.mine == ["b", "0", "1"])
    }
}
