/// RFC 6902 JSON Patch: an ordered sequence of operations applied to a `JSONValue`.
public struct JSONPatch: Sendable {
    public enum Operation: Sendable {
        case add(path: JSONPointer, value: JSONValue)
        case remove(path: JSONPointer)
        case replace(path: JSONPointer, value: JSONValue)
        case move(from: JSONPointer, path: JSONPointer)
        case copy(from: JSONPointer, path: JSONPointer)
        case test(path: JSONPointer, value: JSONValue)
    }

    public let operations: [Operation]

    public init(operations: [Operation]) { self.operations = operations }

    public init(_ json: JSON) throws(JSONPatchError) {
        guard json.isArray else { throw JSONPatchError.invalidOperation }
        var ops: [Operation] = []
        for item in json.arrayValue {
            guard let op = item["op"].string else { throw JSONPatchError.invalidOperation }
            switch op {
            case "add": ops.append(.add(path: try Self.pointer(item, "path"), value: JSONValue(item["value"])))
            case "remove": ops.append(.remove(path: try Self.pointer(item, "path")))
            case "replace": ops.append(.replace(path: try Self.pointer(item, "path"), value: JSONValue(item["value"])))
            case "move": ops.append(.move(from: try Self.pointer(item, "from"), path: try Self.pointer(item, "path")))
            case "copy": ops.append(.copy(from: try Self.pointer(item, "from"), path: try Self.pointer(item, "path")))
            case "test": ops.append(.test(path: try Self.pointer(item, "path"), value: JSONValue(item["value"])))
            default: throw JSONPatchError.invalidOperation
            }
        }
        operations = ops
    }

    private static func pointer(_ item: JSON, _ key: String) throws(JSONPatchError) -> JSONPointer {
        guard let raw = item[key].string, let p = try? JSONPointer(raw) else { throw JSONPatchError.invalidOperation }
        return p
    }

    public func apply(to target: JSONValue) throws(JSONPatchError) -> JSONValue {
        var result = target
        for op in operations {
            switch op {
            case .add(let path, let value):
                result = try result.adding(path.tokens[...], value)
            case .remove(let path):
                result = try result.removing(path.tokens[...])
            case .replace(let path, let value):
                result = try result.replacing(path.tokens[...], value)
            case .move(let from, let path):
                // RFC 6902 §4.4: a location cannot be moved into one of its own children.
                guard !from.isProperPrefix(of: path) else { throw JSONPatchError.invalidOperation }
                guard let moved = result.value(at: from) else { throw JSONPatchError.pathNotFound }
                result = try result.removing(from.tokens[...])
                result = try result.adding(path.tokens[...], moved)
            case .copy(let from, let path):
                guard let value = result.value(at: from) else { throw JSONPatchError.pathNotFound }
                result = try result.adding(path.tokens[...], value)
            case .test(let path, let value):
                guard let actual = result.value(at: path), actual == value else { throw JSONPatchError.testFailed }
            }
        }
        return result
    }
}
