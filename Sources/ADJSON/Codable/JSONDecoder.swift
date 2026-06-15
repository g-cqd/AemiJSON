import ADJSONCore
public import Foundation

extension ADJSON {
    /// Drop-in replacement for `Foundation.JSONDecoder`. Reference as
    /// `ADJSON.JSONDecoder` where Foundation is also imported.
    public struct JSONDecoder {
        public var userInfo: [CodingUserInfoKey: Any] = [:]
        /// Parsing strictness / duplicate-key policy (default: RFC 8259 strict).
        public var options: JSONParseOptions = .strict
        /// How `Date` values are decoded (default `.deferredToDate`, matching Foundation).
        public var dateDecodingStrategy: DateDecodingStrategy = .deferredToDate
        /// How `Data` values are decoded (default `.base64`, matching Foundation).
        public var dataDecodingStrategy: DataDecodingStrategy = .base64
        /// How `±Infinity`/`NaN` are decoded (default `.throw`, matching Foundation).
        public var nonConformingFloatDecodingStrategy: NonConformingFloatDecodingStrategy = .throw
        /// How JSON keys are converted before matching `CodingKey`s (default `.useDefaultKeys`).
        public var keyDecodingStrategy: KeyDecodingStrategy = .useDefaultKeys
        /// Maximum native recursion depth for the (necessarily recursive) Codable decode. Past this,
        /// decoding throws `DecodingError.dataCorrupted` instead of overflowing the call stack — so a
        /// deeply nested or self-referential `Decodable` fails closed. Independent of `options.maxDepth`
        /// (which bounds the *iterative* parser and can be raised freely); default 512. Lower it when
        /// decoding untrusted input on a small-stack worker thread; raise it only on a large stack.
        public var maxDecodingDepth: Int = 512

        /// Assume the top level of the input is an object even without enclosing braces, so
        /// `"a":1,"b":2` decodes as `{"a":1,"b":2}` (matches `Foundation.JSONDecoder`). Applies to
        /// the `Data` / `[UInt8]` decode entry points; a pre-parsed `JSONDocument` is used as-is.
        public var assumesTopLevelDictionary: Bool {
            get { options.assumesTopLevelDictionary }
            set { options.assumesTopLevelDictionary = newValue }
        }

        /// Parse the input as JSON5 (comments, unquoted/single-quoted keys, trailing commas, the
        /// extended number grammar). Matches `Foundation.JSONDecoder.allowsJSON5`. Setting it to
        /// `false` restores strict RFC 8259 parsing.
        public var allowsJSON5: Bool {
            get { if case .json5 = options.validation { return true } else { return false } }
            set { options.validation = newValue ? .json5 : .strict }
        }

        public init() {}

        private var strategies: DecodeStrategies {
            DecodeStrategies(
                date: dateDecodingStrategy, data: dataDecodingStrategy,
                nonConformingFloat: nonConformingFloatDecodingStrategy, key: keyDecodingStrategy)
        }

        public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
            try decode(type, from: try ADJSON.parse(data, options: options))
        }

        public func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
            try decode(type, from: try ADJSON.parse(bytes, options: options))
        }

        /// Decode directly from an already-parsed document (skips re-scanning).
        public func decode<T: Decodable>(_ type: T.Type, from document: JSONDocument) throws -> T {
            try document.withBuffers { bytesBase, byteCount, tapeBase, tapeCount in
                let ctx = DecodeContext(
                    doc: document, bytes: bytesBase, byteCount: byteCount,
                    tape: tapeBase, tapeCount: tapeCount, userInfo: userInfo, strategies: strategies,
                    maxDecodeDepth: maxDecodingDepth)
                return try ctx.decodeValue(T.self, at: 0)
            }
        }
    }
}
