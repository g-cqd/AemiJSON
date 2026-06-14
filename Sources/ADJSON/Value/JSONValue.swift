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
            self = .array(json.arrayValue.map(JSONValue.init))
        } else if json.isObject {
            self = .object(json.objectValue.mapValues(JSONValue.init))
        } else {
            self = .null
        }
    }

    public init(parsing data: Data, options: JSONParseOptions = .strict) throws {
        self.init(try ADJSON.parse(data, options: options).root)
    }

    public init(parsing string: String, options: JSONParseOptions = .strict) throws {
        self.init(try ADJSON.parse(string, options: options).root)
    }

    /// Serialize to compact UTF-8 JSON.
    public func encoded() -> Data {
        let writer = JSONWriter(capacity: 256)
        write(into: writer)
        return Data(writer.bytes)
    }

    func write(into writer: JSONWriter) {
        switch self {
        case .null:
            writer.writeNull()
        case .bool(let b):
            writer.writeBool(b)
        case .number(let d):
            if d.isFinite, d == d.rounded(), abs(d) < 9.007_199_254_740_992e15 {
                writer.writeInteger(Int64(d))
            } else {
                writer.writeDouble(d)
            }
        case .string(let s):
            writer.writeString(s)
        case .array(let elements):
            writer.byte(0x5B)
            for (i, element) in elements.enumerated() {
                if i > 0 { writer.byte(0x2C) }
                element.write(into: writer)
            }
            writer.byte(0x5D)
        case .object(let members):
            writer.byte(0x7B)
            var first = true
            for (key, value) in members {
                if first { first = false } else { writer.byte(0x2C) }
                writer.writeKey(key)
                value.write(into: writer)
            }
            writer.byte(0x7D)
        }
    }
}

// MARK: - JSON Pointer (RFC 6901) access & mutation

extension JSONValue {
    /// The value at an RFC 6901 pointer, or nil if it doesn't resolve.
    public func value(at pointer: JSONPointer) -> JSONValue? {
        var current = self
        for token in pointer.tokens {
            switch current {
            case .object(let members):
                guard let next = members[token] else { return nil }
                current = next
            case .array(let elements):
                guard let i = Int(token), i >= 0, i < elements.count else { return nil }
                current = elements[i]
            default:
                return nil
            }
        }
        return current
    }

    func adding(_ tokens: ArraySlice<String>, _ value: JSONValue) throws -> JSONValue {
        guard let first = tokens.first else { return value }  // empty path replaces the root
        let rest = tokens.dropFirst()
        switch self {
        case .object(var members):
            if rest.isEmpty {
                members[first] = value
            } else {
                guard let child = members[first] else { throw JSONPatchError.pathNotFound }
                members[first] = try child.adding(rest, value)
            }
            return .object(members)
        case .array(var elements):
            if rest.isEmpty {
                if first == "-" {
                    elements.append(value)
                } else {
                    guard let i = Int(first), i >= 0, i <= elements.count else { throw JSONPatchError.pathNotFound }
                    elements.insert(value, at: i)
                }
            } else {
                guard let i = Int(first), i >= 0, i < elements.count else { throw JSONPatchError.pathNotFound }
                elements[i] = try elements[i].adding(rest, value)
            }
            return .array(elements)
        default:
            throw JSONPatchError.pathNotFound
        }
    }

    func removing(_ tokens: ArraySlice<String>) throws -> JSONValue {
        guard let first = tokens.first else { throw JSONPatchError.pathNotFound }
        let rest = tokens.dropFirst()
        switch self {
        case .object(var members):
            guard members[first] != nil else { throw JSONPatchError.pathNotFound }
            if rest.isEmpty {
                members[first] = nil
            } else {
                members[first] = try members[first].map { try $0.removing(rest) }
            }
            return .object(members)
        case .array(var elements):
            guard let i = Int(first), i >= 0, i < elements.count else { throw JSONPatchError.pathNotFound }
            if rest.isEmpty {
                elements.remove(at: i)
            } else {
                elements[i] = try elements[i].removing(rest)
            }
            return .array(elements)
        default:
            throw JSONPatchError.pathNotFound
        }
    }

    func replacing(_ tokens: ArraySlice<String>, _ value: JSONValue) throws -> JSONValue {
        guard let first = tokens.first else { return value }
        let rest = tokens.dropFirst()
        switch self {
        case .object(var members):
            guard members[first] != nil else { throw JSONPatchError.pathNotFound }
            members[first] = rest.isEmpty ? value : try members[first].map { try $0.replacing(rest, value) }
            return .object(members)
        case .array(var elements):
            guard let i = Int(first), i >= 0, i < elements.count else { throw JSONPatchError.pathNotFound }
            elements[i] = rest.isEmpty ? value : try elements[i].replacing(rest, value)
            return .array(elements)
        default:
            throw JSONPatchError.pathNotFound
        }
    }
}

public enum JSONPatchError: Error, Sendable, Equatable {
    case pathNotFound
    case testFailed
    case invalidOperation
}
