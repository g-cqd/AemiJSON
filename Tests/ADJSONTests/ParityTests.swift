import ADTestKit
import Testing

@testable import ADJSON

// Property-based parity between ADJSON's dual recursive/iterative paths. `JSONValue` materialization
// (`materialize` ↔ `buildIteratively`) and serialization (`writeCompact` ↔ `writeIterative`) switch
// from direct recursion to an explicit stack past a fixed fast-depth (128); equality is fully
// iterative. These are asserted byte/result-identical only by comment, so this fuzzes shallow-and-
// wide values (recursive path) and deep-and-narrow values straddling the handoff (iterative path)
// and checks every encoding round-trips to a value equal to the original — so the paths can't
// silently drift.

// Deterministic generator (shared `ADTestKit.SeededRNG`) so a failure reproduces from the
// seed. Used purely as a `RandomNumberGenerator` via the stdlib `.random(in:using:)`, whose
// `next()` stream is byte-for-byte the old local `SeededRNG` — so the corpus is unchanged.

// String content drawn from a pool that exercises escaping (quote, backslash, slash, control chars,
// multi-byte UTF-8) so the encode-escape / parse-unescape round-trip is covered too.
private let stringPool: [Character] = [
    "a", "Z", "9", " ", "\"", "\\", "/", "\n", "\t", "\u{01}", "\u{7F}", "é", "😀", "λ"
]

private func makeString(_ rng: inout SeededRNG) -> String {
    let len = Int.random(in: 0 ... 8, using: &rng)
    var s = ""
    for _ in 0 ..< len { s.append(stringPool[Int.random(in: 0 ..< stringPool.count, using: &rng)]) }
    return s
}

private func makeLeaf(_ rng: inout SeededRNG) -> JSONValue {
    switch Int.random(in: 0 ... 5, using: &rng) {
        case 0: return .null
        case 1: return .bool(.random(using: &rng))
        case 2: return .int(Int64.random(in: -1_000_000_000 ... 1_000_000_000, using: &rng))
        case 3: return .number(Double.random(in: -1_000_000 ... 1_000_000, using: &rng))
        case 4: return .number(Double(Int.random(in: -1000 ... 1000, using: &rng)))  // integral double → "N"
        default: return .string(makeString(&rng))
    }
}

private func makeValue(maxDepth: Int, maxBranch: Int, rng: inout SeededRNG) -> JSONValue {
    if maxDepth <= 0 || Int.random(in: 0 ... 2, using: &rng) == 0 { return makeLeaf(&rng) }
    let branch = Int.random(in: 0 ... maxBranch, using: &rng)
    if Bool.random(using: &rng) {
        return .array((0 ..< branch).map { _ in makeValue(maxDepth: maxDepth - 1, maxBranch: maxBranch, rng: &rng) })
    }
    var pairs: [(String, JSONValue)] = []
    for i in 0 ..< branch {
        // Index prefix guarantees unique keys even when the random suffix collides.
        pairs.append(("k\(i)\(makeString(&rng))", makeValue(maxDepth: maxDepth - 1, maxBranch: maxBranch, rng: &rng)))
    }
    return .object(OrderedDictionary(uniqueKeysWithValues: pairs))
}

// A deep, narrow value (alternating array/object) that forces the iterative materialize/write paths
// past the fast-depth, while staying within the test thread's value-tree dealloc headroom.
private func makeChain(depth: Int, rng: inout SeededRNG) -> JSONValue {
    var v = makeLeaf(&rng)
    for k in 0 ..< depth { v = k.isMultiple(of: 2) ? .array([v]) : .object(["n": v]) }
    return v
}

@Suite("Path parity")
struct ParityTests {
    // Compact (writeCompact / recursive for shallow), sorted-key and pretty (writeIterative) must all
    // round-trip to a value equal to the original — and to each other — after parse + materialize.
    private func expectRoundTrips(_ v: JSONValue, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let opts = JSONParseOptions(maxDepth: 4096)
        // Each serialization path (compact, sorted-key, pretty) must re-parse to a value equal to the
        // original. Routing all three through the shared identity oracle subsumes the former pairwise
        // cross-check, since compact == v ∧ pretty == v already implies compact == pretty.
        expectRoundTripIdentity(v, sourceLocation: sourceLocation) {
            JSONValue(try ADJSON.parse(try $0.encodedBytes(), options: opts).root)
        }
        expectRoundTripIdentity(v, sourceLocation: sourceLocation) {
            JSONValue(
                try ADJSON.parse(
                    try $0.encodedBytes(options: JSONEncodingOptions(keyOrder: .sorted)), options: opts
                )
                .root)
        }
        expectRoundTripIdentity(v, sourceLocation: sourceLocation) {
            JSONValue(
                try ADJSON.parse(
                    try $0.encodedBytes(options: JSONEncodingOptions(prettyPrinted: true)), options: opts
                )
                .root)
        }
    }

    @Test func shallowWideValuesRoundTripAcrossPaths() throws {
        var rng = SeededRNG(seed: 0x5EED_0001)
        for _ in 0 ..< 400 {
            let v = makeValue(maxDepth: Int.random(in: 0 ... 6, using: &rng), maxBranch: 4, rng: &rng)
            try expectRoundTrips(v)
        }
    }

    @Test func deepValuesRoundTripAcrossPaths() throws {
        var rng = SeededRNG(seed: 0x5EED_0002)
        // Depths straddling the fast-depth (128) handoff in both materialize and writeCompact.
        for d in [120, 127, 128, 129, 130, 200, 300] {
            try expectRoundTrips(makeChain(depth: d, rng: &rng))
        }
    }
}
