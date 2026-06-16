import OrderedCollections
import Testing

@testable import ADJSON

// JSON5 support in the pull SAX reader (JSONEventReader), validated against the tape parser as the
// oracle: the same JSON5 document, parsed both ways, must produce the same value.

private func readerValue(_ text: String, options: JSONParseOptions) throws -> JSONValue {
    var reader = JSONEventReader(text, options: options)
    func value(from event: JSONEvent) throws -> JSONValue {
        switch event {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let d): return .number(d)
        case .string(let s): return .string(s)
        case .beginArray:
            var arr: [JSONValue] = []
            while let e = try reader.next() {
                if case .endArray = e { return .array(arr) }
                arr.append(try value(from: e))
            }
            throw JSONError.unexpectedEndOfInput
        case .beginObject:
            var obj = OrderedDictionary<String, JSONValue>()
            while let e = try reader.next() {
                if case .endObject = e { return .object(obj) }
                guard case .key(let k) = e, let ve = try reader.next() else { throw JSONError.unexpectedEndOfInput }
                obj[k] = try value(from: ve)
            }
            throw JSONError.unexpectedEndOfInput
        case .endArray, .endObject, .key: throw JSONError.unexpectedEndOfInput
        }
    }
    guard let first = try reader.next() else { throw JSONError.unexpectedEndOfInput }
    let v = try value(from: first)
    #expect(try reader.next() == nil)  // clean end
    return v
}

@Test func pullReaderJSON5MatchesTapeParser() throws {
    let docs = [
        "{a:1}",  // unquoted key
        "{'a':1, b:2,}",  // single-quoted key, unquoted key, trailing comma
        "[1,2,3,]",  // trailing comma in array
        "// line comment\n{x: 0xFF}",  // line comment + hex number
        "{inf: Infinity, ninf: -Infinity, pos: +3}",  // non-finite + leading +
        #"{s:'it\'s ok', t:"a\nb", u:'\x41'}"#,  // single-quoted escapes, \x
        "/* block */ [.5, 5., -2.5e1, 0x10]",  // block comment + extended numbers
        "{a:1,/*c*/b:2}",  // comment between members
        "{ $id: 1, _x: 2, café: 3 }",  // identifier keys incl. non-ASCII
        "[]",
        "{}",
    ]
    for doc in docs {
        let viaReader = try readerValue(doc, options: .json5)
        let viaTape = JSONValue(try ADJSON.parse(doc, options: .json5).root)
        #expect(viaReader == viaTape, "JSON5 mismatch for: \(doc)\n  reader=\(viaReader)\n  tape=\(viaTape)")
    }
}

@Test func pullReaderJSON5NonFiniteNumbers() throws {
    // NaN can't use `==` (NaN != NaN), so check the kind explicitly.
    let v = try readerValue("{n: NaN, i: Infinity}", options: .json5)
    guard case .object(let o) = v, case .number(let n)? = o["n"], case .number(let i)? = o["i"] else {
        Issue.record("unexpected shape")
        return
    }
    #expect(n.isNaN)
    #expect(i == .infinity)
}

@Test func pullReaderStrictStillRejectsJSON5() {
    // The strict/lenient paths are unchanged: JSON5 constructs must still be rejected under .strict.
    for doc in ["{a:1}", "[1,2,]", "{'a':1}", "// c\n1", "0xFF", "{a:Infinity}"] {
        #expect(throws: JSONError.self) {
            _ = try readerValue(doc, options: .strict)
        }
    }
}

@Test func pullReaderJSON5RejectsMalformed() {
    for doc in ["{a:}", "{1a:2}", "[1 2]", "{a:1 b:2}", "'unterminated", "{a:'b'", "0xG1"] {
        #expect(throws: JSONError.self) {
            _ = try readerValue(doc, options: .json5)
        }
    }
}
