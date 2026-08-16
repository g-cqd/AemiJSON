import AemiTestKit
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
    for _ in 0 ..< depth { s = #"{"next":["# + s + "]}" }
    return s
}

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

    @Test func iterativeMaterializerMatchesLazyViewPastFastDepth() throws {
        // `JSONValue(_:)` recurses directly up to `maxFastDepth` (128) and hands deeper subtrees to the
        // explicit-stack `buildIteratively`. Exercise that fallback (which the parity suites otherwise
        // never reach) with object- and array-nesting deeper than 128, carrying mixed scalars and
        // multi-member objects at each level, and assert the materialized tree is byte-identical to a
        // re-parse and that re-encoding round-trips exactly.
        func deepObject(_ depth: Int) -> String {
            // {"k":<int>,"child":{…}} nested `depth` deep, innermost child an array of scalars + object.
            var s = #"{"leaf":[1,-2,3.5,"x",true,null,{"a":1,"b":2}]}"#
            for d in 0 ..< depth { s = #"{"i":\#(d),"child":\#(s),"flag":\#(d % 2 == 0)}"# }
            return s
        }
        // The materialize/round-trip recurses up to `maxFastDepth` (128) before the iterative fallback
        // takes over — enough native frames to overflow the ~512 KB swift-testing cooperative-pool
        // stack under ASan. Run that work on AemiTestKit's pinned stack (4 MiB under a sanitizer) and pass
        // only the Sendable `JSONValue` results back for the assertions on the test thread.
        for depth in [129, 200, 400] {  // all strictly past maxFastDepth so the iterative path runs
            let text = deepObject(depth)
            let opts = JSONParseOptions(maxDepth: depth + 8)
            let trees = runOnConstrainedStack(stackSize: DepthSweep.defaultStackSize, name: "materialize.obj") {
                () -> (materialized: JSONValue, viaBytes: JSONValue, reparsed: JSONValue)? in
                guard let root = try? ADJSON.parse(text, options: opts).root else { return nil }
                let materialized = JSONValue(root)  // buildIteratively / BuildFrame
                guard let viaBytes = try? JSONValue(parsing: text, options: opts),
                    let encoded = try? materialized.encodedBytes(),  // re-encode is also iterative past maxFastDepth
                    let reparsed = try? JSONValue(parsing: String(decoding: encoded, as: UTF8.self), options: opts)
                else { return nil }
                return (materialized, viaBytes, reparsed)
            }
            let got = try #require(trees, "depth \(depth): deep materialize/round-trip threw")
            #expect(got.materialized == got.viaBytes, "depth \(depth): iterative materialize diverged")
            #expect(got.reparsed == got.materialized, "depth \(depth): round-trip changed the tree")
        }
        // A deep array spine (>128) with a trailing object leaf — the array branch of BuildFrame.
        let arrDepth = 300
        let arrText =
            String(repeating: "[", count: arrDepth) + #"{"k":"v","n":7}"#
            + String(repeating: "]", count: arrDepth)
        let opts = JSONParseOptions(maxDepth: arrDepth + 8)
        let arr = runOnConstrainedStack(stackSize: DepthSweep.defaultStackSize, name: "materialize.arr") {
            () -> (mat: JSONValue, viaBytes: JSONValue)? in
            guard let root = try? ADJSON.parse(arrText, options: opts).root,
                let viaBytes = try? JSONValue(parsing: arrText, options: opts)
            else { return nil }
            return (JSONValue(root), viaBytes)
        }
        let gotArr = try #require(arr, "arrDepth \(arrDepth): deep materialize threw")
        #expect(gotArr.mat == gotArr.viaBytes)
    }

    @Test func decoderRecursionGuardFailsClosed() throws {
        // A `Decodable` that recurses per nesting level. This runs on a swift-testing cooperative-pool
        // thread (~512 KB), which ASan-inflated frames overflow well before a cap of ~50 — and
        // `@MainActor` does NOT move the recursion onto the 8 MB main thread under swift-testing. So the
        // cap is set low (8, as `schemaValidationBoundsDeepRecursion`) to fire while the stack still has
        // wide margin; a deeply nested document then throws a catchable error instead of crashing.
        struct DeepArray: Decodable {
            init(from decoder: any Decoder) throws {
                var c = try decoder.unkeyedContainer()
                while !c.isAtEnd { _ = try c.decode(DeepArray.self) }
            }
        }
        var decoder = ADJSON.JSONDecoder()
        decoder.maxDecodingDepth = 8  // sanitizer-safe: fires before the ~512 KB pool stack overflows under ASan
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
            for _ in 0 ..< depth { value = .array([value]) }
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
        // Instance nested deeper than the (low) cap. `validate` frames are heavy (a `SchemaNode`
        // copy each) and this runs on a swift-testing cooperative-pool thread (~512 KB stack), so the
        // cap must keep recursion shallow enough that the GUARD — not the stack — stops the descent.
        // The threshold is sanitizer-sensitive: a debug frame overflowed a small worker stack around
        // ~50 frames, but ASan inflates each frame ~2-3×, dropping the ceiling to ~20. A cap of 8
        // (≈9 frames; ~2 frames per instance level) keeps a wide margin under ASan while still firing.
        let dInstance = 24
        let it = String(repeating: "[", count: dInstance) + String(repeating: "]", count: dInstance)
        let instance = try ADJSON.parse(it, options: JSONParseOptions(maxDepth: dInstance + 1)).root
        let validator = SchemaValidator(nodes: schema.nodes, registry: schema.registry, maxValidationDepth: 8)
        var path: [String] = []
        var errors: [ValidationError] = []
        let ok = validator.validate(schema.rootIndex, instance, &path, &errors)
        #expect(!ok)  // failed closed (recorded an error, did not crash)
        #expect(errors.contains { $0.message.contains("maximum nesting depth") })
        // A shallow instance still validates cleanly against the same schema (default cap).
        #expect(try schema.validate(ADJSON.parse("[[[]]]").root).isValid)
    }

    // The cap is set low (8) so the guard fires while the ~512 KB cooperative-pool stack still has wide
    // margin under ASan frame inflation (see `decoderRecursionGuardFailsClosed`; `@MainActor` does not
    // move the recursion off that stack under swift-testing).
    @Test func fastPathDecodeRecursionFailsClosed() throws {
        // The macro fast path decodes array elements by calling `__adjsonDecode` directly (bypassing
        // the generic container decoder the existing test covers). A deeply nested recursive
        // `@JSONCodable` type must throw, not overflow `fastArray` / `decodeValue`.
        var decoder = ADJSON.JSONDecoder()
        decoder.maxDecodingDepth = 8  // sanitizer-safe (see above)
        decoder.options = JSONParseOptions(maxDepth: 1000)
        let deep = deepFastNodeJSON(120)
        #expect(throws: DecodingError.self) { try decoder.decode(FastNode.self, from: Data(deep.utf8)) }
        // A shallow value still decodes via the same fast path.
        let shallow = try decoder.decode(FastNode.self, from: Data(#"{"next":[{"next":[]}]}"#.utf8))
        #expect(shallow.next.count == 1)
    }

    @Test func concurrentDecodeHonorsDepthCap() async throws {
        // The concurrent path runs element decoders on the cooperative pool's small (~512 KB) stacks,
        // which ASan-inflated frames overflow well before a cap of 50. A low cap (8) makes the guard,
        // not the stack, reject the over-nested element on the pool thread (as the sibling guards).
        let arrayText = "[" + deepFastNodeJSON(120) + "]"
        await #expect(throws: DecodingError.self) {
            _ = try await ADJSON.decodeArrayConcurrently(
                FastNode.self, from: Data(arrayText.utf8), maxDecodingDepth: 8)
        }
        // A shallow array still decodes concurrently.
        let ok = try await ADJSON.decodeArrayConcurrently(
            FastNode.self, from: Data(#"[{"next":[]},{"next":[]}]"#.utf8))
        #expect(ok.count == 2)
    }

    // The cap is set low (8) so the guard fires while the ~512 KB cooperative-pool stack still has wide
    // margin under ASan (see `decoderRecursionGuardFailsClosed`).
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
        encoder.maxEncodingDepth = 8  // sanitizer-safe: fires before the ~512 KB pool stack overflows under ASan
        #expect(throws: EncodingError.self) { try encoder.encode(SelfEncode()) }
        // Normal-depth values still encode.
        #expect(try encoder.encode([1, 2, 3]) == Data("[1,2,3]".utf8))
    }

    // Pinned to the main actor: `maxMutationDepth` (256) is sized for the main-thread stack budget,
    // so exercising it needs a stack that can actually hold ~256 frames. swift-testing's default
    // cooperative-pool thread (~512 KB) can't once ASan inflates each frame ~2-3×, so the recursion
    // would overflow before the guard fires. The 8 MB main-thread stack keeps the GUARD — not the
    // stack — in control.
    @MainActor @Test func patchAndMergeBoundDeepRecursion() throws {
        // JSON Patch pointer mutation recurses once per path token; a pointer deeper than the cap
        // over a matching tree must throw `JSONPatchError.depthExceeded`, not overflow.
        let d = 300
        var target: JSONValue = .int(0)
        for _ in 0 ..< d { target = .object(["a": target]) }
        let pointer = JSONPointer(tokens: Array(repeating: "a", count: d))
        let patch = JSONPatch(operations: [.replace(path: pointer, value: .int(1))])
        #expect(throws: JSONPatchError.self) { try patch.apply(to: target) }

        // RFC 7396 merge-patch is non-throwing: past the cap it degrades to a replace, so a deep patch
        // completes (no crash) rather than recursing without bound.
        var deepPatch: JSONValue = .int(1)
        for _ in 0 ..< d { deepPatch = .object(["a": deepPatch]) }
        let merged = JSONMergePatch.apply(deepPatch, to: .object([:]))
        #expect(merged.value(at: JSONPointer(tokens: ["a"])) != nil)
    }
}
