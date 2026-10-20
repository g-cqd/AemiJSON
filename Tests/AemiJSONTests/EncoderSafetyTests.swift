import AemiJSON
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Regression coverage for the encoder/inference fail-safe fixes: a keyed `superEncoder()` must emit
/// a `"super"` key (not a keyless value), and the recursive `JSONValue(encoding:)` and schema
/// inference paths must fail closed on pathological depth instead of overflowing the native stack.
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
        let bytes = try AemiJSON.JSONEncoder().encodeToBytes(UsesSuper())
        // Was malformed (`{"a":1{"x":2}}`) before the key was emitted.
        #expect(String(decoding: bytes, as: UTF8.self) == #"{"a":1,"super":{"x":2}}"#)
        let doc = try AemiJSON.parse(bytes)
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

    // The recursive `JSONValue(encoding:)` fires the guard at the bound. The bound is set low (8) so it
    // fires while the ~512 KB cooperative-pool stack still has wide margin under ASan frame inflation
    // (`@MainActor` does not move the recursion onto the main thread under swift-testing; see
    // DepthSafetyTests). `Chain` is built only 24 deep so its own recursive init stays shallow too.
    @Test func jsonValueEncodingBoundsDepth() throws {
        _ = try JSONValue(encoding: Chain(8))  // shallow nesting round-trips
        // A graph deeper than the bound fails closed (EncodingError) rather than overflowing the
        // native stack.
        #expect(throws: EncodingError.self) { try JSONValue(encoding: Chain(24), maxDepth: 8) }
    }

    // MARK: Schema inference is depth-bounded

    // `infer` is iterative (no native-stack recursion), so a deeply nested sample is shape-summarized
    // without overflowing the small test-thread stack; the clamp bounds the accumulator it builds.
    @Test func inferenceBoundsDepthOnDeepInput() throws {
        var nested = "1"
        for _ in 0 ..< 4000 { nested = #"{"a":"# + nested + "}" }
        var options = JSONParseOptions.strict
        options.maxDepth = 5000  // the iterative parser is safe at any depth
        let root = try AemiJSON.parse(nested, options: options).root
        // Must return a bounded schema rather than overflowing the native stack.
        let schema = JSONSchema.infer(from: [root])
        #expect(schema.contains(#""type":"object""#))
    }

    // MARK: Multiple containers on one encoder (Issue #4)

    private struct MultipleKeyedContainers: Encodable {
        enum A: String, CodingKey { case type }
        enum B: String, CodingKey { case extra }
        func encode(to encoder: any Encoder) throws {
            var a = encoder.container(keyedBy: A.self)
            try a.encode("t", forKey: .type)
            var b = encoder.container(keyedBy: B.self)
            try b.encode(1, forKey: .extra)
        }
    }

    private struct InterleavedKeyedContainers: Encodable {
        enum A: String, CodingKey { case first, third }
        enum B: String, CodingKey { case second }
        func encode(to encoder: any Encoder) throws {
            var a = encoder.container(keyedBy: A.self)
            try a.encode("1", forKey: .first)
            var b = encoder.container(keyedBy: B.self)
            try b.encode("2", forKey: .second)
            try a.encode("3", forKey: .third)
        }
    }

    private struct NestedThenKeyedContainer: Encodable {
        enum A: String, CodingKey { case meta }
        enum B: String, CodingKey { case count }
        enum MetaKeys: String, CodingKey { case version }
        func encode(to encoder: any Encoder) throws {
            var a = encoder.container(keyedBy: A.self)
            var nested = a.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
            try nested.encode(2, forKey: .version)
            var b = encoder.container(keyedBy: B.self)
            try b.encode(42, forKey: .count)
        }
    }

    private struct MultipleUnkeyedContainers: Encodable {
        func encode(to encoder: any Encoder) throws {
            var a = encoder.unkeyedContainer()
            try a.encode(1)
            var b = encoder.unkeyedContainer()
            try b.encode(2)
            try a.encode(3)
        }
    }

    @Test func multipleKeyedContainersMergeIntoOneObject() throws {
        var encoder = AemiJSON.JSONEncoder()
        let compact = try encoder.encode(MultipleKeyedContainers())
        #expect(String(decoding: compact, as: UTF8.self) == #"{"type":"t","extra":1}"#)

        encoder.options = JSONEncodingOptions(keyOrder: .sorted)
        let sorted = try encoder.encode(MultipleKeyedContainers())
        #expect(String(decoding: sorted, as: UTF8.self) == #"{"extra":1,"type":"t"}"#)

        encoder.prettyPrinted = true
        let pretty = try encoder.encode(MultipleKeyedContainers())
        #expect(String(decoding: pretty, as: UTF8.self) == "{\n  \"extra\" : 1,\n  \"type\" : \"t\"\n}")

        let direct = try JSONValue(encoding: MultipleKeyedContainers())
        #expect(direct == .object(["type": .string("t"), "extra": .int(1)]))
    }

    @Test func interleavedKeyedContainersMergeInOrder() throws {
        let encoder = AemiJSON.JSONEncoder()
        let bytes = try encoder.encode(InterleavedKeyedContainers())
        #expect(String(decoding: bytes, as: UTF8.self) == #"{"first":"1","second":"2","third":"3"}"#)

        let direct = try JSONValue(encoding: InterleavedKeyedContainers())
        #expect(direct == .object(["first": .string("1"), "second": .string("2"), "third": .string("3")]))
    }

    @Test func nestedContainerClosesBeforeSubsequentKeyedMember() throws {
        let encoder = AemiJSON.JSONEncoder()
        let bytes = try encoder.encode(NestedThenKeyedContainer())
        #expect(String(decoding: bytes, as: UTF8.self) == #"{"meta":{"version":2},"count":42}"#)
    }

    @Test func multipleUnkeyedContainersAppendToSameArray() throws {
        let encoder = AemiJSON.JSONEncoder()
        let bytes = try encoder.encode(MultipleUnkeyedContainers())
        #expect(String(decoding: bytes, as: UTF8.self) == "[1,2,3]")

        let direct = try JSONValue(encoding: MultipleUnkeyedContainers())
        #expect(direct == .array([.int(1), .int(2), .int(3)]))
    }

    // MARK: userInfo reaches the encoder

    private struct ReadsUserInfo: Encodable {
        static let key = CodingUserInfoKey(rawValue: "tag")!
        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            let tag = encoder.userInfo[Self.key] as? String ?? "missing"
            try c.encode(tag)
        }
    }

    @Test func userInfoReachesTapeEncoder() throws {
        var encoder = AemiJSON.JSONEncoder()
        encoder.userInfo[ReadsUserInfo.key] = "hello"
        let data = try encoder.encode(ReadsUserInfo())
        #expect(String(decoding: data, as: UTF8.self) == #""hello""#)
    }

    // MARK: Mismatched container types fail

    private struct MismatchedContainers: Encodable {
        enum Mode { case keyedThenUnkeyed, keyedThenSingle, unkeyedThenKeyed }
        let mode: Mode
        enum K: String, CodingKey { case a }
        func encode(to encoder: any Encoder) throws {
            switch mode {
                case .keyedThenUnkeyed:
                    _ = encoder.container(keyedBy: K.self)
                    _ = encoder.unkeyedContainer()
                case .keyedThenSingle:
                    _ = encoder.container(keyedBy: K.self)
                    _ = encoder.singleValueContainer()
                case .unkeyedThenKeyed:
                    _ = encoder.unkeyedContainer()
                    _ = encoder.container(keyedBy: K.self)
            }
        }
    }

    @Test func requestingMismatchedContainerTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = try AemiJSON.JSONEncoder().encode(MismatchedContainers(mode: .keyedThenUnkeyed))
        }
        await #expect(processExitsWith: .failure) {
            _ = try AemiJSON.JSONEncoder().encode(MismatchedContainers(mode: .keyedThenSingle))
        }
        await #expect(processExitsWith: .failure) {
            _ = try AemiJSON.JSONEncoder().encode(MismatchedContainers(mode: .unkeyedThenKeyed))
        }
    }
}
