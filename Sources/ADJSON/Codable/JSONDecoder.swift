import Foundation

extension ADJSON {
    /// Drop-in replacement for `Foundation.JSONDecoder`. Reference as
    /// `ADJSON.JSONDecoder` where Foundation is also imported.
    public struct JSONDecoder {
        public var userInfo: [CodingUserInfoKey: Any] = [:]
        /// Parsing strictness / duplicate-key policy (default: RFC 8259 strict).
        public var options: JSONParseOptions = .strict

        public init() {}

        public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
            try decode(type, from: try ADJSON.parse(data, options: options))
        }

        public func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
            try decode(type, from: try ADJSON.parse(bytes, options: options))
        }

        /// Decode directly from an already-parsed document (skips re-scanning).
        public func decode<T: Decodable>(_ type: T.Type, from document: JSONDocument) throws -> T {
            try document.withBuffers { bytesBase, tapeBase in
                let ctx = DecodeContext(doc: document, bytes: bytesBase, tape: tapeBase, userInfo: userInfo)
                return try ctx.decodeValue(T.self, at: 0)
            }
        }
    }
}
