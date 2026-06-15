import Foundation
import Testing

@testable import ADJSON

// Depth-safety: ADJSON's iterative paths (parse / lazy nav / SAX / JSONPath descent) handle nesting
// far beyond Foundation's hard 512 cap, while the unavoidably recursive Codable decoder now *fails
// closed* (throws) instead of overflowing the stack. See the stack-exhaustion harness report.

@Suite("Depth safety")
struct DepthSafetyTests {
    @Test func iterativeParseGoesFarBeyondFoundationCap() throws {
        // 50k nesting — ~100× Foundation's 512 — parses iteratively with no stack overflow.
        let depth = 50_000
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let root = try ADJSON.parse(nested, options: JSONParseOptions(maxDepth: depth + 1)).root
        var node = root
        var levels = 0
        while node.isArray, node.count == 1 {
            node = node[index: 0]
            levels += 1
        }
        #expect(levels == depth - 1)
        // SAX over the same input is likewise iterative.
        var reader = JSONEventReader(nested, options: JSONParseOptions(maxDepth: depth + 1))
        var begins = 0
        while let event = try reader.next(), event == .beginArray { begins += 1 }
        #expect(begins == depth)
    }

    @Test func decoderRecursionGuardFailsClosed() throws {
        // A `Decodable` that recurses per nesting level. With the guard set below the (small) test
        // thread's capacity, a deeply nested document throws a catchable error instead of crashing.
        struct DeepArray: Decodable {
            init(from decoder: any Decoder) throws {
                var c = try decoder.unkeyedContainer()
                while !c.isAtEnd { _ = try c.decode(DeepArray.self) }
            }
        }
        var decoder = ADJSON.JSONDecoder()
        decoder.maxDecodingDepth = 100  // fire well before the thread stack runs out
        decoder.options = JSONParseOptions(maxDepth: 1000)  // the iterative parser accepts deep input
        let nested = String(repeating: "[", count: 300) + String(repeating: "]", count: 300)
        #expect(throws: DecodingError.self) { try decoder.decode(DeepArray.self, from: Data(nested.utf8)) }

        // A self-referential type that adds no JSON structure (the classic decoder bomb) is caught by
        // the same guard rather than recursing forever / overflowing.
        struct SelfRec: Decodable {
            init(from decoder: any Decoder) throws {
                _ = try decoder.singleValueContainer().decode(SelfRec.self)
            }
        }
        #expect(throws: DecodingError.self) { try decoder.decode(SelfRec.self, from: Data("0".utf8)) }

        // Normal-depth input still decodes.
        #expect(try decoder.decode([Int].self, from: Data("[1,2,3]".utf8)) == [1, 2, 3])
    }

    @Test func equalityIsIterativeAndCorrect() throws {
        // `==` walks an explicit stack, so deep trees compare without overflowing (a recursive `==`
        // crashed ~37k deep). 500 levels is safe to bulk-release on the test thread.
        func deepArray(_ depth: Int, leaf: JSONValue) -> JSONValue {
            var value = leaf
            for _ in 0..<depth { value = .array([value]) }
            return value
        }
        #expect(deepArray(500, leaf: .int(1)) == deepArray(500, leaf: .int(1)))
        #expect(deepArray(500, leaf: .int(1)) != deepArray(500, leaf: .int(2)))
    }
}
