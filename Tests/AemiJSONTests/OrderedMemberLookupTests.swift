import AemiJSONCore
import Foundation
import Testing

@testable import AemiJSON

// Roadmap 0002. `Decodable` asks for keys in declaration order, which is usually the document's order. A lookup that starts from the
// object's first member every time costs O(k²) comparisons for an object of k keys; one that starts where the previous key was found
// costs O(k) when the orders agree. Duplicate keys keep their meaning: the last spelling wins unless the document was parsed with
// `.throwError`.

/// The keys `k0` … `k(n-1)`.
private struct IndexKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(_ i: Int) { stringValue = "k\(i)" }
}

/// Reads `k0` … `k(count-1)`, forward or backward, from a keyed container.
private struct Wide: Decodable {
    static let count = 64
    nonisolated(unsafe) static var reversed = false
    var values: [Int]

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: IndexKey.self)
        var values = [Int](repeating: -1, count: Self.count)
        let order = Self.reversed ? Array((0 ..< Self.count).reversed()) : Array(0 ..< Self.count)
        for i in order { values[i] = try c.decode(Int.self, forKey: IndexKey(i)) }
        self.values = values
    }
}

private func wideDocument(_ n: Int = Wide.count) -> [UInt8] {
    Array(("{" + (0 ..< n).map { "\"k\($0)\":\($0 * 10)" }.joined(separator: ",") + "}").utf8)
}

/// Decodes with the comparison counter bound and returns the result and the count.
private func counting<T>(_ body: () throws -> T) rethrows -> (T, Int) {
    let counter = KeyComparisonCounter()
    let value = try KeyComparisonCounter.$current.withValue(counter) { try body() }
    return (value, counter.count)
}

@Suite(.serialized) struct OrderedMemberLookupTests {
    @Test func inOrderLookupIsLinearUnderTheDefaultOptions() throws {
        Wide.reversed = false
        let (wide, comparisons) = try counting { try AemiJSON.JSONDecoder().decode(Wide.self, from: wideDocument()) }
        #expect(wide.values == (0 ..< Wide.count).map { $0 * 10 })
        #expect(comparisons <= 2 * Wide.count, "\(comparisons) comparisons for \(Wide.count) keys in order")
    }

    @Test func inOrderLookupIsLinearWhenDuplicatesAreErrors() throws {
        Wide.reversed = false
        var decoder = AemiJSON.JSONDecoder()
        decoder.options.duplicateKeys = .throwError
        let (wide, comparisons) = try counting { try decoder.decode(Wide.self, from: wideDocument()) }
        #expect(wide.values == (0 ..< Wide.count).map { $0 * 10 })
        #expect(comparisons <= 2 * Wide.count, "\(comparisons) comparisons for \(Wide.count) keys in order")
    }

    @Test func reverseOrderLookupStillFindsEveryKey() throws {
        Wide.reversed = true
        defer { Wide.reversed = false }
        let wide = try AemiJSON.JSONDecoder().decode(Wide.self, from: wideDocument())
        #expect(wide.values == (0 ..< Wide.count).map { $0 * 10 })
    }

    @Test func theLastDuplicateWinsInAWideObject() throws {
        Wide.reversed = false
        // k3 appears twice; the later spelling (after k63) holds 999.
        var text = String(decoding: wideDocument(), as: UTF8.self)
        text.removeLast()
        text += #","k3":999}"#
        let wide = try AemiJSON.JSONDecoder().decode(Wide.self, from: Array(text.utf8))
        #expect(wide.values[3] == 999)
        #expect(wide.values[4] == 40)
    }

    @Test func anEscapedSpellingOfAKeyIsStillADuplicate() throws {
        Wide.reversed = false
        var text = String(decoding: wideDocument(), as: UTF8.self)
        text.removeLast()
        text += #","\u006b5":555}"#  // "k5"
        let wide = try AemiJSON.JSONDecoder().decode(Wide.self, from: Array(text.utf8))
        #expect(wide.values[5] == 555)
        #expect(wide.values[6] == 60)
    }

    @Test func missingAndPresentKeysInterleave() throws {
        struct Sparse: Decodable {
            var a: Int?
            var b: Int?
            var c: Int?
            var d: Int?
            var e: Int?
        }
        let s = try AemiJSON.JSONDecoder().decode(Sparse.self, from: Array(#"{"e":5,"a":1,"c":3,"x":0}"#.utf8))
        #expect(s.a == 1 && s.b == nil && s.c == 3 && s.d == nil && s.e == 5)
    }

    @Test func nestedObjectsKeepTheirOwnPlace() throws {
        struct Inner: Decodable, Equatable {
            var p: Int
            var q: Int
            var r: Int
            var s: Int
            var t: Int
        }
        struct Outer: Decodable, Equatable {
            var a: Int
            var b: Inner
            var c: Int
            var d: Inner
            var e: Int
        }
        let inner = #"{"p":1,"q":2,"r":3,"s":4,"t":5}"#
        let text = #"{"a":1,"b":\#(inner),"c":3,"d":\#(inner),"e":5}"#
        let (outer, comparisons) = try counting {
            try AemiJSON.JSONDecoder().decode(Outer.self, from: Array(text.utf8))
        }
        let i = Inner(p: 1, q: 2, r: 3, s: 4, t: 5)
        #expect(outer == Outer(a: 1, b: i, c: 3, d: i, e: 5))
        #expect(comparisons <= 2 * 15, "\(comparisons) comparisons for 15 keys in order")
    }

    // The macro path resolves its fields in one walk of the object and is not bounded here (roadmap 0008).
    @Test func theMacroPathReadsEveryField() throws {
        let text = #"{"f0":0,"f1":1,"f2":2,"f3":3,"f4":4,"f5":5,"f6":6,"f7":7,"f8":8,"f9":9,"f10":10,"f11":11}"#
        let value = try AemiJSON.JSONDecoder().decode(Twelve.self, from: Array(text.utf8))
        #expect(value.f0 == 0 && value.f5 == 5 && value.f11 == 11)
    }

    @Test func theMacroPathKeepsTheLastDuplicate() throws {
        let text =
            #"{"f0":0,"f1":1,"f2":2,"f3":3,"f4":4,"f5":5,"f6":6,"f7":7,"f8":8,"f9":9,"f10":10,"f11":11,"f0":100}"#
        let value = try AemiJSON.JSONDecoder().decode(Twelve.self, from: Array(text.utf8))
        #expect(value.f0 == 100 && value.f1 == 1)
    }
}

@JSONCodable
private struct Twelve: Codable {
    var f0: Int
    var f1: Int
    var f2: Int
    var f3: Int
    var f4: Int
    var f5: Int
    var f6: Int
    var f7: Int
    var f8: Int
    var f9: Int
    var f10: Int
    var f11: Int
}
