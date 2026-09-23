import AemiJSON
import Foundation
import Testing

// The by-key readers of `_FastDecodeCursor` (`c.string("k")`, `c.stringIfPresent("k")`, …) serve
// hand-written fast conformances. They walk the members of the object at the cursor, so each one must
// first check that the node is an object: a string's slot holds its length where an object's holds
// its member count, and walking that as members reads past the end of the tape.

/// One by-key reader, applied to the member `"k"`.
private protocol ByKeyRead: Sendable {
    static func read(_ c: _FastDecodeCursor) throws
}

private enum ReadString: ByKeyRead {
    static func read(_ c: _FastDecodeCursor) throws { _ = try c.string("k") }
}
private enum ReadStringIfPresent: ByKeyRead {
    static func read(_ c: _FastDecodeCursor) throws { _ = try c.stringIfPresent("k") }
}
private enum ReadBool: ByKeyRead {
    static func read(_ c: _FastDecodeCursor) throws { _ = try c.bool("k") }
}
private enum ReadBoolIfPresent: ByKeyRead {
    static func read(_ c: _FastDecodeCursor) throws { _ = try c.boolIfPresent("k") }
}
private enum ReadDouble: ByKeyRead {
    static func read(_ c: _FastDecodeCursor) throws { _ = try c.double("k") }
}
private enum ReadDoubleIfPresent: ByKeyRead {
    static func read(_ c: _FastDecodeCursor) throws { _ = try c.doubleIfPresent("k") }
}
private enum ReadInteger: ByKeyRead {
    static func read(_ c: _FastDecodeCursor) throws { _ = try c.integer("k", Int.self) }
}
private enum ReadIntegerIfPresent: ByKeyRead {
    static func read(_ c: _FastDecodeCursor) throws { _ = try c.integerIfPresent("k", Int.self) }
}
private enum ReadDecode: ByKeyRead {
    static func read(_ c: _FastDecodeCursor) throws { _ = try c.decode([Int].self, "k") }
}
private enum ReadDecodeIfPresent: ByKeyRead {
    static func read(_ c: _FastDecodeCursor) throws { _ = try c.decodeIfPresent([Int].self, "k") }
}

private let byKeyReaders: [any ByKeyRead.Type] = [
    ReadString.self, ReadStringIfPresent.self, ReadBool.self, ReadBoolIfPresent.self, ReadDouble.self,
    ReadDoubleIfPresent.self, ReadInteger.self, ReadIntegerIfPresent.self, ReadDecode.self,
    ReadDecodeIfPresent.self
]

/// A minimal hand-written fast conformance that hands its cursor to one by-key reader. Its generic
/// `init(from:)` succeeds without reading, so a test that expects a throw cannot pass through it.
private struct ByKeyProbe<Read: ByKeyRead>: Decodable, AemiJSONFastDecodable {
    init() {}
    init(from decoder: any Decoder) throws { self.init() }
    static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
        try Read.read(c)
        return Self()
    }
}

private func decodeProbe<Read: ByKeyRead>(_ read: Read.Type, _ json: String) throws {
    _ = try AemiJSON.JSONDecoder().decode(ByKeyProbe<Read>.self, from: Data(json.utf8))
}

struct FastDecodeCursorTests {
    // A three-character string was enough to read past the tape: its slot's count field is
    // `(3 << 2) | flags`, so the member walk visited twelve slots of a one-slot tape.
    @Test(arguments: [#""abc""#, "42", "[1,2,3]", "true", "null", #""\#(String(repeating: "x", count: 4096))""#])
    func byKeyReadersRejectANonObjectWithTypeMismatch(_ json: String) {
        for reader in byKeyReaders {
            let error = #expect(throws: DecodingError.self, "\(reader) on \(json.prefix(12))") {
                try decodeProbe(reader, json)
            }
            if case .typeMismatch? = error { continue }
            Issue.record("\(reader) on \(json.prefix(12)): expected typeMismatch, got \(String(describing: error))")
        }
    }

    @Test func byKeyReadersStillReadObjectMembers() throws {
        let optionalReaders: [any ByKeyRead.Type] = [ReadStringIfPresent.self, ReadBoolIfPresent.self]
        for reader in optionalReaders {
            try decodeProbe(reader, #"{"other":1}"#)  // an absent key reads as nil, without throwing
        }
        try decodeProbe(ReadString.self, #"{"k":"v"}"#)
        try decodeProbe(ReadBool.self, #"{"k":true}"#)
        try decodeProbe(ReadDouble.self, #"{"k":1.5}"#)
        try decodeProbe(ReadInteger.self, #"{"k":7}"#)
        try decodeProbe(ReadDecode.self, #"{"k":[1,2]}"#)
        try decodeProbe(ReadDecodeIfPresent.self, #"{"k":null}"#)
    }
}
