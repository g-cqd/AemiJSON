import Foundation
import Testing

@testable import ADJSON

// Depth-safety: ADJSON's iterative paths (parse / lazy nav / SAX / JSONPath descent) handle nesting
// far beyond Foundation's hard 512 cap, while the unavoidably recursive Codable decoder now *fails
// closed* (throws) instead of overflowing the stack. See the stack-exhaustion harness report.

// A recursive type that opts into the macro fast path (`@JSONCodable` → `ADJSONFastDecodable`), so
// decoding it exercises `_FastDecodeCursor.fastArray` / `decodeValue` rather than the generic
// container decoder the existing tests cover.
@JSONCodable
private struct FastNode: Codable, Sendable {
    var next: [FastNode]
}

// node(0) = {"next":[]}; node(n) wraps node(n-1) one level deeper.
private func deepFastNodeJSON(_ depth: Int) -> String {
    var s = #"{"next":[]}"#
    for _ in 0..<depth { s = #"{"next":["# + s + "]}" }
    return s
}

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

    @Test func jsonPathParserBoundsNestedLength() throws {
        // `length(length(…(@)…))` recurses in `parseComparand`; without the depth guard a crafted
        // nest overflows the parser stack (and the AST would then overflow `evalComparand`). Well
        // past `JSONPathParser.maxDepth` (64) the parse must be REJECTED, not crash.
        let n = 300
        let path = "$[?" + String(repeating: "length(", count: n) + "@" + String(repeating: ")", count: n) + "==1]"
        #expect(throws: JSONPathError.self) { try JSONPath(path) }
        // A shallow `length()` still parses and evaluates.
        let arr = try ADJSON.parse("[[1,2],[3],[4,5]]")
        #expect(try arr.root.query("$[?length(@)==2]").count == 2)
    }

    @Test func schemaValidationBoundsDeepRecursion() throws {
        // A recursive ($ref-linked) schema descends one frame per instance level, so a deep instance
        // — independent of the schema's own size — could overflow with no catchable error. With a low
        // cap the validator fails CLOSED (records an error, returns invalid) rather than crashing.
        let schemaJSON = ##"{"$ref":"#/$defs/a","$defs":{"a":{"type":"array","items":{"$ref":"#/$defs/a"}}}}"##
        let schema = try JSONSchema(parsing: schemaJSON)
        // Instance nested deeper than the (low) cap; `validate` frames are heavy (a `SchemaNode`
        // copy each), so a low cap keeps the guard firing well within the small test thread's stack.
        let dInstance = 60
        let it = String(repeating: "[", count: dInstance) + String(repeating: "]", count: dInstance)
        let instance = try ADJSON.parse(it, options: JSONParseOptions(maxDepth: dInstance + 1)).root
        var validator = SchemaValidator(nodes: schema.nodes, registry: schema.registry, maxValidationDepth: 30)
        var path = [String]()
        var errors = [ValidationError]()
        let ok = validator.validate(schema.rootIndex, instance, &path, &errors)
        #expect(!ok)  // failed closed (recorded an error, did not crash)
        #expect(errors.contains { $0.message.contains("maximum nesting depth") })
        // A shallow instance still validates cleanly against the same schema (default cap).
        #expect(try schema.validate(ADJSON.parse("[[[]]]").root).isValid)
    }

    @Test func fastPathDecodeRecursionFailsClosed() throws {
        // The macro fast path decodes array elements by calling `__adjsonDecode` directly (bypassing
        // the generic container decoder the existing test covers). A deeply nested recursive
        // `@JSONCodable` type must throw, not overflow `fastArray` / `decodeValue`.
        var decoder = ADJSON.JSONDecoder()
        decoder.maxDecodingDepth = 50
        decoder.options = JSONParseOptions(maxDepth: 1000)
        let deep = deepFastNodeJSON(120)
        #expect(throws: DecodingError.self) { try decoder.decode(FastNode.self, from: Data(deep.utf8)) }
        // A shallow value still decodes via the same fast path.
        let shallow = try decoder.decode(FastNode.self, from: Data(#"{"next":[{"next":[]}]}"#.utf8))
        #expect(shallow.next.count == 1)
    }

    @Test func concurrentDecodeHonorsDepthCap() async throws {
        // The concurrent path runs element decoders on the cooperative pool's small stacks; passing a
        // low `maxDecodingDepth` must make an over-nested element throw rather than crash a pool thread.
        let arrayText = "[" + deepFastNodeJSON(120) + "]"
        await #expect(throws: DecodingError.self) {
            _ = try await ADJSON.decodeArrayConcurrently(
                FastNode.self, from: Data(arrayText.utf8), maxDecodingDepth: 50)
        }
        // A shallow array still decodes concurrently.
        let ok = try await ADJSON.decodeArrayConcurrently(
            FastNode.self, from: Data(#"[{"next":[]},{"next":[]}]"#.utf8))
        #expect(ok.count == 2)
    }

    @Test func encoderRecursionGuardFailsClosed() throws {
        // A self-referential `Encodable` (the encode-side bomb, symmetric with the decoder) is caught
        // by `EncodeState`'s depth guard and throws instead of overflowing the stack.
        struct SelfEncode: Encodable {
            func encode(to encoder: any Encoder) throws {
                var c = encoder.singleValueContainer()
                try c.encode(SelfEncode())
            }
        }
        var encoder = ADJSON.JSONEncoder()
        encoder.maxEncodingDepth = 100  // fire well before the test thread's stack runs out
        #expect(throws: EncodingError.self) { try encoder.encode(SelfEncode()) }
        // Normal-depth values still encode.
        #expect(try encoder.encode([1, 2, 3]) == Data("[1,2,3]".utf8))
    }

    @Test func patchAndMergeBoundDeepRecursion() throws {
        // JSON Patch pointer mutation recurses once per path token; a pointer deeper than the cap
        // over a matching tree must throw `JSONPatchError.depthExceeded`, not overflow. (Depth kept
        // above the 256 cap but within the test thread's value-tree dealloc headroom.)
        let d = 300
        var target: JSONValue = .int(0)
        for _ in 0..<d { target = .object(["a": target]) }
        let pointer = JSONPointer(tokens: Array(repeating: "a", count: d))
        let patch = JSONPatch(operations: [.replace(path: pointer, value: .int(1))])
        #expect(throws: JSONPatchError.self) { try patch.apply(to: target) }

        // RFC 7396 merge-patch is non-throwing: past the cap it degrades to a replace, so a deep patch
        // completes (no crash) rather than recursing without bound.
        var deepPatch: JSONValue = .int(1)
        for _ in 0..<d { deepPatch = .object(["a": deepPatch]) }
        let merged = JSONMergePatch.apply(deepPatch, to: .object([:]))
        #expect(merged.value(at: JSONPointer(tokens: ["a"])) != nil)
    }
}
