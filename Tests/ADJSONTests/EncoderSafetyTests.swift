import ADJSON
import Testing

/// Regression coverage for the encoder/inference fail-safe fixes: a keyed `superEncoder()` must emit
/// a `"super"` key (not a keyless value), and the recursive `JSONValue(encoding:)` and schema
/// inference paths must fail closed on pathological depth instead of overflowing the native stack.
@Suite("Encoder safety")
struct EncoderSafetyTests {
    // MARK: superEncoder emits a "super" key

    private struct UsesSuper: Encodable {
        enum K: String, CodingKey { case a }
        enum SK: String, CodingKey { case x }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(1, forKey: .a)
            var sc = c.superEncoder().container(keyedBy: SK.self)
            try sc.encode(2, forKey: .x)
        }
    }

    @Test func keyedSuperEncoderEmitsSuperKey() throws {
        let bytes = try ADJSON.JSONEncoder().encodeToBytes(UsesSuper())
        // Was malformed (`{"a":1{"x":2}}`) before the key was emitted.
        #expect(String(decoding: bytes, as: UTF8.self) == #"{"a":1,"super":{"x":2}}"#)
        let doc = try ADJSON.parse(bytes)
        #expect(doc.root.a.int == 1)
        #expect(doc.root["super"].x.int == 2)
    }

    // MARK: JSONValue(encoding:) bounds recursion

    private final class Chain: Encodable {
        let child: Chain?
        init(_ depth: Int) { child = depth > 0 ? Chain(depth - 1) : nil }
        enum K: CodingKey { case child }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encodeIfPresent(child, forKey: .child)
        }
    }

    @Test func jsonValueEncodingBoundsDepth() throws {
        _ = try JSONValue(encoding: Chain(8))  // shallow nesting round-trips
        // A graph deeper than the bound fails closed (EncodingError) rather than overflowing the
        // native stack. A small bound fires the guard well before the test thread's stack runs out
        // (mirrors DepthSafetyTests' `maxEncodingDepth = 100`).
        #expect(throws: EncodingError.self) { try JSONValue(encoding: Chain(300), maxDepth: 100) }
    }

    // MARK: Schema inference is depth-bounded

    // `infer` is iterative (no native-stack recursion), so a deeply nested sample is shape-summarized
    // without overflowing the small test-thread stack; the clamp bounds the accumulator it builds.
    @Test func inferenceBoundsDepthOnDeepInput() throws {
        var nested = "1"
        for _ in 0 ..< 4000 { nested = #"{"a":"# + nested + "}" }
        var options = JSONParseOptions.strict
        options.maxDepth = 5000  // the iterative parser is safe at any depth
        let root = try ADJSON.parse(nested, options: options).root
        // Must return a bounded schema rather than overflowing the native stack.
        let schema = JSONSchema.infer(from: [root])
        #expect(schema.contains(#""type":"object""#))
    }
}
