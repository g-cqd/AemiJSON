import Foundation
import Testing

@testable import ADJSON

private struct DateBox: Codable, Equatable { var when: Date }
private struct DataBox: Codable, Equatable { var blob: Data }
private struct DoubleBox: Codable, Equatable { var v: Double }

private let sampleDate = Date(timeIntervalSince1970: 1_700_000_000)  // whole seconds → ISO/seconds exact
private let sampleData = Data([0x00, 0x01, 0x02, 0xFF, 0x10, 0xAB])

// MARK: - Date

@Test func dateSecondsSince1970MatchesFoundation() throws {
    var aEnc = ADJSON.JSONEncoder()
    aEnc.dateEncodingStrategy = .secondsSince1970
    let fEnc = Foundation.JSONEncoder()
    fEnc.dateEncodingStrategy = .secondsSince1970
    var aDec = ADJSON.JSONDecoder()
    aDec.dateDecodingStrategy = .secondsSince1970
    let fDec = Foundation.JSONDecoder()
    fDec.dateDecodingStrategy = .secondsSince1970
    let box = DateBox(when: sampleDate)
    let a = try aEnc.encode(box)
    #expect(try ADJSON.parse(a).root.when.double == 1_700_000_000)
    #expect(try fDec.decode(DateBox.self, from: a) == box)
    #expect(try aDec.decode(DateBox.self, from: fEnc.encode(box)) == box)
}

@Test func dateMillisecondsSince1970MatchesFoundation() throws {
    var aEnc = ADJSON.JSONEncoder()
    aEnc.dateEncodingStrategy = .millisecondsSince1970
    let fDec = Foundation.JSONDecoder()
    fDec.dateDecodingStrategy = .millisecondsSince1970
    var aDec = ADJSON.JSONDecoder()
    aDec.dateDecodingStrategy = .millisecondsSince1970
    let fEnc = Foundation.JSONEncoder()
    fEnc.dateEncodingStrategy = .millisecondsSince1970
    let box = DateBox(when: sampleDate)
    let a = try aEnc.encode(box)
    #expect(try ADJSON.parse(a).root.when.double == 1_700_000_000_000)
    #expect(try fDec.decode(DateBox.self, from: a) == box)
    #expect(try aDec.decode(DateBox.self, from: fEnc.encode(box)) == box)
}

@Test func dateISO8601MatchesFoundation() throws {
    var aEnc = ADJSON.JSONEncoder()
    aEnc.dateEncodingStrategy = .iso8601
    let fEnc = Foundation.JSONEncoder()
    fEnc.dateEncodingStrategy = .iso8601
    var aDec = ADJSON.JSONDecoder()
    aDec.dateDecodingStrategy = .iso8601
    let fDec = Foundation.JSONDecoder()
    fDec.dateDecodingStrategy = .iso8601
    let box = DateBox(when: sampleDate)
    let a = try aEnc.encode(box)
    // ISO8601 internet date-time string, byte-identical to Foundation.
    #expect(a == (try fEnc.encode(box)))
    #expect(try fDec.decode(DateBox.self, from: a) == box)
    #expect(try aDec.decode(DateBox.self, from: a) == box)
}

@Test func deferredToDateIsDefaultAndRoundTrips() throws {
    let box = DateBox(when: sampleDate)
    let adjsonBytes = try ADJSON.JSONEncoder().encode(box)  // default = .deferredToDate
    #expect(try Foundation.JSONDecoder().decode(DateBox.self, from: adjsonBytes) == box)
    let foundationBytes = try Foundation.JSONEncoder().encode(box)
    #expect(try ADJSON.JSONDecoder().decode(DateBox.self, from: foundationBytes) == box)
}

// MARK: - Data

@Test func dataBase64IsDefaultAndMatchesFoundation() throws {
    let box = DataBox(blob: sampleData)
    let adjsonBytes = try ADJSON.JSONEncoder().encode(box)  // default = .base64
    // Compare the decoded Base64 payload (ADJSON leaves `/` unescaped, Foundation escapes it).
    #expect(try ADJSON.parse(adjsonBytes).root.blob.string == "AAEC/xCr")
    #expect(try Foundation.JSONDecoder().decode(DataBox.self, from: adjsonBytes) == box)
    let foundationBytes = try Foundation.JSONEncoder().encode(box)
    #expect(try ADJSON.JSONDecoder().decode(DataBox.self, from: foundationBytes) == box)
}

@Test func dataDeferredToDataEncodesByteArray() throws {
    let box = DataBox(blob: Data([1, 2, 3]))
    var enc = ADJSON.JSONEncoder()
    enc.dataEncodingStrategy = .deferredToData
    let bytes = try enc.encode(box)
    #expect(String(decoding: bytes, as: UTF8.self) == #"{"blob":[1,2,3]}"#)
    var dec = ADJSON.JSONDecoder()
    dec.dataDecodingStrategy = .deferredToData
    #expect(try dec.decode(DataBox.self, from: bytes) == box)
}

// MARK: - Non-conforming float

@Test func nonConformingFloatDecodesFromConfiguredStrings() throws {
    var dec = ADJSON.JSONDecoder()
    dec.nonConformingFloatDecodingStrategy = .convertFromString(
        positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
    #expect(try dec.decode(DoubleBox.self, from: Data(#"{"v":"Infinity"}"#.utf8)).v == .infinity)
    #expect(try dec.decode(DoubleBox.self, from: Data(#"{"v":"-Infinity"}"#.utf8)).v == -.infinity)
    #expect(try dec.decode(DoubleBox.self, from: Data(#"{"v":"NaN"}"#.utf8)).v.isNaN)
    // Plain numbers still decode normally.
    #expect(try dec.decode(DoubleBox.self, from: Data(#"{"v":3.5}"#.utf8)).v == 3.5)
}

@Test func nonConformingFloatDefaultRejectsStrings() {
    #expect(throws: (any Error).self) {
        try ADJSON.JSONDecoder().decode(DoubleBox.self, from: Data(#"{"v":"Infinity"}"#.utf8))
    }
}

// MARK: - Key strategies

private struct SnakeModel: Codable, Equatable {
    var firstName: String
    var lastName: String
    var ageInYears: Int
    var nested: Inner

    struct Inner: Codable, Equatable {
        var streetName: String
    }
}

@Test func keyEncodingConvertsToSnakeCaseLikeFoundation() throws {
    let model = SnakeModel(firstName: "Ada", lastName: "L", ageInYears: 36, nested: .init(streetName: "Main"))
    var adj = ADJSON.JSONEncoder()
    adj.keyEncodingStrategy = .convertToSnakeCase
    adj.options = JSONEncodingOptions(keyOrder: .sorted)  // deterministic order for comparison
    let fnd = Foundation.JSONEncoder()
    fnd.keyEncodingStrategy = .convertToSnakeCase
    fnd.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    #expect(
        String(decoding: try adj.encode(model), as: UTF8.self)
            == String(decoding: try fnd.encode(model), as: UTF8.self))
}

@Test func snakeCaseHandlesAcronymsLikeFoundation() throws {
    struct Acro: Encodable {
        var aURL: Int
        var someID: Int
        var plainWord: Int
    }
    let v = Acro(aURL: 1, someID: 2, plainWord: 3)
    var adj = ADJSON.JSONEncoder()
    adj.keyEncodingStrategy = .convertToSnakeCase
    adj.options = JSONEncodingOptions(keyOrder: .sorted)
    let fnd = Foundation.JSONEncoder()
    fnd.keyEncodingStrategy = .convertToSnakeCase
    fnd.outputFormatting = [.sortedKeys]
    #expect(
        String(decoding: try adj.encode(v), as: UTF8.self) == String(decoding: try fnd.encode(v), as: UTF8.self))
}

@Test func keyDecodingConvertsFromSnakeCase() throws {
    let json = Data(
        #"{"first_name":"Ada","last_name":"L","age_in_years":36,"nested":{"street_name":"Main"}}"#.utf8)
    var adj = ADJSON.JSONDecoder()
    adj.keyDecodingStrategy = .convertFromSnakeCase
    let fnd = Foundation.JSONDecoder()
    fnd.keyDecodingStrategy = .convertFromSnakeCase
    let expected = SnakeModel(firstName: "Ada", lastName: "L", ageInYears: 36, nested: .init(streetName: "Main"))
    #expect(try adj.decode(SnakeModel.self, from: json) == expected)
    #expect(try fnd.decode(SnakeModel.self, from: json) == expected)  // sanity: same as Foundation
}

@Test func keyStrategyRoundTripsThroughSnakeCase() throws {
    let model = SnakeModel(firstName: "Grace", lastName: "H", ageInYears: 85, nested: .init(streetName: "Pine"))
    var enc = ADJSON.JSONEncoder()
    enc.keyEncodingStrategy = .convertToSnakeCase
    var dec = ADJSON.JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    #expect(try dec.decode(SnakeModel.self, from: enc.encode(model)) == model)
}

@Test func snakeCaseAppliesToDictionaryKeys() throws {
    var enc = ADJSON.JSONEncoder()
    enc.keyEncodingStrategy = .convertToSnakeCase
    // Dictionaries take the fast path by default; the key strategy must still apply.
    let out = try ADJSON.parse(try enc.encode(["camelKey": 1])).root
    #expect(out.camel_key.int == 1)
}
