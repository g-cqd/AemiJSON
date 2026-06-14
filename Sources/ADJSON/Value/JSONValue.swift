public import Foundation

/// A fully-materialized, mutable JSON value tree. The lazy `JSON` view is read-only
/// over a parsed document; `JSONValue` is the editable counterpart used by JSON Patch
/// (RFC 6902) and JSON Merge Patch (RFC 7396).
///
/// Numbers are held as `Double`; integers beyond 2^53 lose precision (documented).
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    /// Materialize from a lazy `JSON` view.
    public init(_ json: JSON) {
        if json.isNull {
            self = .null
        } else if let b = json.bool {
            self = .bool(b)
        } else if let d = json.double {
            self = .number(d)
        } else if let s = json.string {
            self = .string(s)
        } else if json.isArray {
            var elements = [JSONValue]()
            elements.reserveCapacity(json.count)
            json.forEachElement { elements.append(JSONValue($0)) }
            self = .array(elements)
        } else if json.isObject {
            var members = [String: JSONValue](minimumCapacity: json.count)
            json.forEachMember { members[$0] = JSONValue($1) }
            self = .object(members)
        } else {
            self = .null
        }
    }

    public init(parsing data: Data, options: JSONParseOptions = .strict) throws(JSONError) {
        self.init(try ADJSON.parse(data, options: options).root)
    }

    public init(parsing string: String, options: JSONParseOptions = .strict) throws(JSONError) {
        self.init(try ADJSON.parse(string, options: options).root)
    }

    /// The deepest array/object nesting `encoded()` will serialize before failing. Mirrors
    /// the parser's `maxDepth` so a value that round-trips through parse always re-encodes.
    static let maxEncodingDepth = 512

    /// Serialize to compact UTF-8 JSON using the given profile. The default (`.rfc8259`) is strict
    /// and throws `EncodingError.invalidValue` on a non-finite number; pass `.javaScript` for
    /// `JSON.stringify` byte-parity (non-finite → `null`, ECMA-262 number formatting). Also throws
    /// if the tree nests beyond `maxEncodingDepth`.
    public func encoded(options: JSONEncodingOptions = .rfc8259) throws -> Data {
        let writer = JSONWriter(capacity: 256)
        try write(into: writer, depth: 0, options: options)
        return Data(writer.bytes)
    }

    func write(into writer: JSONWriter, depth: Int, options: JSONEncodingOptions) throws {
        guard depth <= Self.maxEncodingDepth else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: [], debugDescription: "Nesting exceeds \(Self.maxEncodingDepth)"))
        }
        switch self {
        case .null:
            writer.writeNull()
        case .bool(let b):
            writer.writeBool(b)
        case .number(let d):
            try writeNumber(d, into: writer, options: options)
        case .string(let s):
            writer.writeString(s)
        case .array(let elements):
            writer.byte(0x5B)
            for (i, element) in elements.enumerated() {
                if i > 0 { writer.byte(0x2C) }
                try element.write(into: writer, depth: depth + 1, options: options)
            }
            writer.byte(0x5D)
        case .object(let members):
            writer.byte(0x7B)
            let pairs = options.keyOrder == .sorted ? members.sorted { $0.key < $1.key } : Array(members)
            for (i, pair) in pairs.enumerated() {
                if i > 0 { writer.byte(0x2C) }
                writer.writeKey(pair.key)
                try pair.value.write(into: writer, depth: depth + 1, options: options)
            }
            writer.byte(0x7D)
        }
    }

    // Number emission for the value model. Under `.swiftShortest` an integral magnitude below 2^53
    // is rendered without a fractional part (`2`, not `2.0`) so a JSON integer survives a
    // parse → `JSONValue` → `encoded()` round-trip unchanged — `JSONValue` only stores `Double`,
    // so it cannot otherwise tell `2` from `2.0`. This intentionally differs from the Codable
    // encode path, where a value typed `Double` is faithfully rendered as `2.0` (see
    // `JSONEncodingOptions.NumberFormat.swiftShortest`). Neither path reproduces Foundation's
    // formatter byte-for-byte; use `.ecma262` for `JSON.stringify` parity.
    private func writeNumber(_ d: Double, into writer: JSONWriter, options: JSONEncodingOptions) throws {
        guard d.isFinite else {
            switch options.nonFinite {
            case .throw:
                throw EncodingError.invalidValue(
                    d, .init(codingPath: [], debugDescription: "Non-finite \(d) cannot be encoded as JSON"))
            case .null:
                writer.writeNull()
            case .stringLiterals(let pos, let neg, let nan):
                writer.writeString(d.isNaN ? nan : (d > 0 ? pos : neg))
            }
            return
        }
        switch options.numberFormat {
        case .ecma262:
            JSONOutput.appendECMANumber(d, to: &writer.bytes)
        case .swiftShortest:
            if d == d.rounded(), abs(d) < 9.007_199_254_740_992e15 {
                writer.writeInteger(Int64(d))
            } else {
                writer.writeDouble(d)
            }
        }
    }
}
