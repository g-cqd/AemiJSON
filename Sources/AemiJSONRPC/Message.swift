public import AemiJSONCore
internal import OrderedCollections

/// A request's id: JSON-RPC 2.0 allows an integer or a string.
public enum JSONRPCID: Sendable, Hashable, CustomStringConvertible {
    case number(Int64)
    case string(String)

    /// The id as JSON.
    public var jsonValue: JSONValue {
        switch self {
            case .number(let n): .int(n)
            case .string(let s): .string(s)
        }
    }

    public var description: String {
        switch self {
            case .number(let n): String(n)
            case .string(let s): s
        }
    }

    /// The id `json` holds, or nil when it holds something an id cannot be.
    init?(_ json: JSON) {
        if let n = json.int {
            self = .number(Int64(n))
        } else if let s = json.string {
            self = .string(s)
        } else {
            return nil
        }
    }
}

/// A JSON-RPC 2.0 error object.
public struct JSONRPCError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Invalid JSON was received.
    public static let parseError = -32700
    /// The JSON sent is not a valid request object.
    public static let invalidRequest = -32600
    /// The method does not exist or is not available.
    public static let methodNotFound = -32601
    /// Invalid method parameters.
    public static let invalidParams = -32602
    /// An internal JSON-RPC error.
    public static let internalError = -32603

    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var description: String { "JSON-RPC error \(code): \(message)" }

    var jsonValue: JSONValue {
        var members: OrderedDictionary<String, JSONValue> = ["code": .int(Int64(code)), "message": .string(message)]
        if let data { members["data"] = data }
        return .object(members)
    }
}

/// A request: it has an id, and the peer answers it.
public struct JSONRPCRequest: Sendable {
    public let id: JSONRPCID
    public let method: String
    /// The parameters, an object or an array; nil when absent.
    public let params: JSON?
}

/// A notification: it has no id, and nobody answers it.
public struct JSONRPCNotification: Sendable {
    public let method: String
    /// The parameters, an object or an array; nil when absent.
    public let params: JSON?
}

/// One JSON-RPC 2.0 message. Batches are not read: an array is an invalid request.
public enum JSONRPCMessage: Sendable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    /// A response: the result or the error, for the id (nil when the peer could not read the request's id).
    case response(id: JSONRPCID?, Result<JSON, JSONRPCError>)

    /// Why a body is not a message: the error to answer with, and the id to answer under when one could be read.
    public struct Invalid: Error, Sendable, Equatable {
        public let error: JSONRPCError
        public let id: JSONRPCID?

        /// The error response that answers it.
        public func response() throws -> [UInt8] { try JSONRPC.response(id: id, error: error) }
    }

    /// Reads a message from a body.
    /// - Throws: ``Invalid``, with ``JSONRPCError/parseError`` when the body is not JSON and ``JSONRPCError/invalidRequest`` when it is
    ///   JSON but not a message.
    public init(parsing body: [UInt8]) throws(Invalid) {
        let root: JSON
        do {
            root = try AemiJSON.parse(body).root
        } catch {
            throw Invalid(error: JSONRPCError(code: JSONRPCError.parseError, message: "parse error: \(error)"), id: nil)
        }
        try self.init(root)
    }

    private init(_ root: JSON) throws(Invalid) {
        guard root.isObject else { throw Self.invalid("a message is an object", id: nil) }
        let idMember = root["id"]
        let id = idMember.exists ? JSONRPCID(idMember) : nil
        guard root["jsonrpc"].string == "2.0" else { throw Self.invalid("jsonrpc is not \"2.0\"", id: id) }
        guard !idMember.exists || idMember.isNull || id != nil else {
            throw Self.invalid("an id is an integer or a string", id: nil)
        }
        let method = root["method"]
        if method.exists {
            guard let name = method.string else { throw Self.invalid("method is not a string", id: id) }
            let params = root["params"]
            guard !params.exists || params.isObject || params.isArray else {
                throw Self.invalid("params is not an object or an array", id: id)
            }
            let present = params.exists ? params : nil
            guard idMember.exists else {
                self = .notification(JSONRPCNotification(method: name, params: present))
                return
            }
            guard let id else { throw Self.invalid("a request's id is not null", id: nil) }
            self = .request(JSONRPCRequest(id: id, method: name, params: present))
            return
        }
        let result = root["result"]
        let error = root["error"]
        guard idMember.exists, result.exists != error.exists else {
            throw Self.invalid("a response has an id and one of result and error", id: id)
        }
        if result.exists {
            self = .response(id: id, .success(result))
            return
        }
        guard let code = error["code"].int, let message = error["message"].string else {
            throw Self.invalid("an error has an integer code and a string message", id: id)
        }
        let data = error["data"]
        let failure = JSONRPCError(code: code, message: message, data: data.exists ? JSONValue(data) : nil)
        self = .response(id: id, .failure(failure))
    }

    private static func invalid(_ message: String, id: JSONRPCID?) -> Invalid {
        Invalid(error: JSONRPCError(code: JSONRPCError.invalidRequest, message: "invalid request: \(message)"), id: id)
    }
}

/// Writes JSON-RPC 2.0 messages as unframed bodies; ``JSONRPCFraming/frame(_:)`` frames them.
///
/// Members are written in the order `jsonrpc`, `id`, `method`, `result` or `error`, `params`. Each writer throws only when a value holds a
/// number JSON cannot spell (NaN, an infinity).
public enum JSONRPC {
    /// A request.
    public static func request(id: JSONRPCID, method: String, params: JSONValue? = nil) throws -> [UInt8] {
        try envelope(id: id.jsonValue, ("method", .string(method)), params: params)
    }

    /// A notification.
    public static func notification(method: String, params: JSONValue? = nil) throws -> [UInt8] {
        try envelope(id: nil, ("method", .string(method)), params: params)
    }

    /// A response carrying `result`, under `id` (null when nil).
    public static func response(id: JSONRPCID?, result: JSONValue) throws -> [UInt8] {
        try envelope(id: id?.jsonValue ?? .null, ("result", result), params: nil)
    }

    /// A response carrying `error`, under `id` (null when nil).
    public static func response(id: JSONRPCID?, error: JSONRPCError) throws -> [UInt8] {
        try envelope(id: id?.jsonValue ?? .null, ("error", error.jsonValue), params: nil)
    }

    private static func envelope(id: JSONValue?, _ member: (String, JSONValue), params: JSONValue?) throws -> [UInt8] {
        var members: OrderedDictionary<String, JSONValue> = ["jsonrpc": "2.0"]
        if let id { members["id"] = id }
        members[member.0] = member.1
        if let params { members["params"] = params }
        return try JSONValue.object(members).encodedBytes()
    }
}
