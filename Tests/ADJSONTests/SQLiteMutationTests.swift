import Testing

@testable import ADJSON

// Parity of `JSONValue.setting(_:to:mode:)` / `removing(_:)` with SQLite's json_set / json_insert /
// json_replace / json_remove. Expected outputs were generated from `sqlite3 :memory:` (3.54.0).
@Suite("SQLite mutation parity")
struct SQLiteMutationTests {
    private func materialize(_ s: String) throws -> JSONValue { JSONValue(try ADJSON.parse(s).root) }
    private func enc(_ v: JSONValue) throws -> String {
        String(decoding: try v.encodedBytes(options: .sqlite), as: UTF8.self)
    }
    private func set(
        _ input: String, _ path: String, _ value: String, _ mode: JSONValue.SQLiteSetMode
    ) throws
        -> String
    {
        try enc(materialize(input).setting(try SQLiteJSONPath(path), to: materialize(value), mode: mode))
    }

    // (input, path, value, mode, expected)
    static let corpus: [(String, String, String, JSONValue.SQLiteSetMode, String)] = [
        // json_set
        (#"{"a":1}"#, "$.a", "2", .set, #"{"a":2}"#),
        (#"{"a":1}"#, "$.b", "2", .set, #"{"a":1,"b":2}"#),
        (#"{}"#, "$.a.b", "1", .set, #"{"a":{"b":1}}"#),
        (#"{}"#, "$.a[0]", "1", .set, #"{"a":[1]}"#),
        (#"{}"#, "$.a.b.c", "1", .set, #"{"a":{"b":{"c":1}}}"#),
        (#"[1,2,3]"#, "$[1]", "9", .set, #"[1,9,3]"#),
        (#"[1,2]"#, "$[#]", "3", .set, #"[1,2,3]"#),
        (#"[1,2]"#, "$[5]", "9", .set, #"[1,2]"#),  // index past end ⇒ no-op
        (#"[1,2,3]"#, "$[#-1]", "9", .set, #"[1,2,9]"#),  // from-end replace
        (#"[1,2]"#, "$[2]", "9", .set, #"[1,2,9]"#),  // index == count ⇒ append
        (#"[1,2]"#, "$[3]", "9", .set, #"[1,2]"#),  // index > count ⇒ no-op
        (#"[1,2,3]"#, "$[#-0]", "9", .set, #"[1,2,3,9]"#),  // [#-0] == append
        (#"[1,2,3]"#, "$[#-5]", "9", .set, #"[1,2,3]"#),  // from-end underflow ⇒ no-op
        (#"{"a":1}"#, "$", "5", .set, #"5"#),  // root overwrite
        (#"{"a":1}"#, "$.a.b", "5", .set, #"{"a":1}"#),  // descend into scalar ⇒ no-op
        (#"{"a":1}"#, "$[0]", "5", .set, #"{"a":1}"#),  // index an object ⇒ no-op
        (#"[1,2]"#, "$.a", "5", .set, #"[1,2]"#),  // key an array ⇒ no-op
        (#"{}"#, "$.a[5]", "1", .set, #"{}"#),  // create-then-OOB ⇒ no intermediate
        (#"[]"#, "$[0][5]", "1", .set, #"[]"#),  // append-then-OOB ⇒ no intermediate
        (#"{}"#, "$.a[0].b", "5", .set, #"{"a":[{"b":5}]}"#),
        (#"{}"#, "$.a.b[0]", "1", .set, #"{"a":{"b":[1]}}"#),
        (#"{}"#, "$.a[0][0]", "1", .set, #"{"a":[[1]]}"#),
        (#"{}"#, "$.u", #""a/b""#, .set, #"{"u":"a/b"}"#),  // string value, slash raw
        // json_insert (create only if missing)
        (#"{"a":1}"#, "$.a", "2", .insert, #"{"a":1}"#),  // exists ⇒ no-op
        (#"{"a":1}"#, "$.b", "2", .insert, #"{"a":1,"b":2}"#),
        (#"[1,2]"#, "$[#]", "3", .insert, #"[1,2,3]"#),
        (#"[1,2,3]"#, "$[1]", "9", .insert, #"[1,2,3]"#),  // existing index ⇒ no-op
        (#"[1,2]"#, "$[2]", "9", .insert, #"[1,2,9]"#),  // append position
        (#"{"a":1}"#, "$", "5", .insert, #"{"a":1}"#),  // root exists ⇒ no-op
        // json_replace (overwrite only if present)
        (#"{"a":1}"#, "$.a", "2", .replace, #"{"a":2}"#),
        (#"{"a":1}"#, "$.b", "2", .replace, #"{"a":1}"#),  // missing ⇒ no-op
        (#"{}"#, "$.a.b", "1", .replace, #"{}"#),  // missing intermediate ⇒ no-op
        (#"{"a":1}"#, "$", "5", .replace, #"5"#),  // root always replaceable
    ]

    @Test(arguments: corpus)
    func setInsertReplaceMatchSQLite(_ c: (String, String, String, JSONValue.SQLiteSetMode, String)) throws {
        #expect(try set(c.0, c.1, c.2, c.3) == c.4)
    }

    @Test func removeMatchesSQLite() throws {
        func rem(_ input: String, _ path: String) throws -> String? {
            guard let out = try materialize(input).removing(try SQLiteJSONPath(path)) else { return nil }
            return try enc(out)
        }
        #expect(try rem(#"{"a":1,"b":2}"#, "$.b") == #"{"a":1}"#)
        #expect(try rem(#"{"a":1}"#, "$.b") == #"{"a":1}"#)  // missing ⇒ no-op
        #expect(try rem(#"{"a":{"b":1,"c":2}}"#, "$.a.b") == #"{"a":{"c":2}}"#)
        #expect(try rem(#"[1,2,3]"#, "$[1]") == #"[1,3]"#)
        #expect(try rem(#"[1,2,3]"#, "$[#-1]") == #"[1,2]"#)  // from-end
        #expect(try rem(#"[1,2]"#, "$[9]") == #"[1,2]"#)  // out of range ⇒ no-op
        #expect(try rem(#"[1,2]"#, "$[#]") == #"[1,2]"#)  // append position ⇒ no-op
        #expect(try rem(#"{"a":1}"#, "$") == nil)  // remove the whole value ⇒ nil
    }

    // Pinned to the main actor: a pathologically deep path recurses up to `maxMutationDepth` (256)
    // before failing closed, and 256 ASan-inflated frames overflow the swift-testing cooperative-pool
    // stack — the 8 MB main-thread stack keeps the guard (not the stack) in control. Past the cap the
    // operation is a no-op, so the value is returned unchanged rather than crashing.
    @MainActor @Test func deepPathFailsClosed() throws {
        let path = try SQLiteJSONPath("$" + String(repeating: ".a", count: 400))
        let result = JSONValue.object([:]).setting(path, to: .int(1), mode: .set)
        #expect(result == .object([:]))
    }
}
