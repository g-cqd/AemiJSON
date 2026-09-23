import AemiJSONCore
#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

extension AemiJSON {
    /// Drop-in replacement for `Foundation.JSONDecoder`. Reference as
    /// `AemiJSON.JSONDecoder` where Foundation is also imported.
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
        /// (which bounds the *iterative* parser and can be raised freely). Every nested value other than
        /// a scalar — an object, an array, or a custom `Decodable` — counts one level, so an array of
        /// objects nests two levels deep: the array, then each object.
        ///
        /// Default **64**, sized for the 512 KiB stacks that actors and the cooperative pool run on,
        /// where most decoding happens. Measured on a 512 KiB thread in a debug build, a keyed class
        /// with 32 optional fields overflows at ~150 levels and an untyped JSON value decoded through a
        /// `try?` chain at ~220 (two levels per JSON level); release builds reach 2–3× deeper. 64 keeps
        /// those under half the stack. **Raise it** when decoding legitimately deep data on a thread
        /// with a known large stack: an 8 MiB stack, the main thread's size, holds ~2,400 levels of
        /// the 32-field class in a debug build.
        public var maxDecodingDepth: Int = JSONDecoder.defaultMaxDecodingDepth

        /// The default ``maxDecodingDepth``, shared with the concurrent decoder.
        static let defaultMaxDecodingDepth = 64

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
            get {
                guard case .json5 = options.validation else { return false }
                return true
            }
            set { options.validation = newValue ? .json5 : .strict }
        }

        public init() {}

        private var strategies: DecodeStrategies {
            DecodeStrategies(
                date: dateDecodingStrategy, data: dataDecodingStrategy,
                nonConformingFloat: nonConformingFloatDecodingStrategy, key: keyDecodingStrategy)
        }

        public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
            try decode(type, from: try AemiJSON.parse(data, options: options))
        }

        public func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
            try decode(type, from: try AemiJSON.parse(bytes, options: options))
        }

        /// Decode directly from an already-parsed document (skips re-scanning).
        public func decode<T: Decodable>(_ type: T.Type, from document: JSONDocument) throws -> T {
            try document.withDecodeContext(
                userInfo: userInfo, strategies: strategies, maxDecodeDepth: maxDecodingDepth
            ) { ctx in try ctx.decodeValue(T.self, at: 0) }
        }

        /// Decode directly from an already-materialized ``JSONValue``, skipping the serialize-and-reparse
        /// round-trip a caller would otherwise pay to reuse the byte / `JSONDocument` decoders. This is
        /// the generic container path (the `@JSONCodable` fast path is tape-bound and does not apply), but
        /// it honors the same Date/Data/key/non-conforming-float strategies and the `maxDecodingDepth`
        /// guard, so the result matches `decode(_:from:)` on the equivalent bytes.
        public func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
            let decoder = JSONValueDecoderImpl(
                value: value, codingPath: [], userInfo: userInfo, strategies: strategies, depth: 0,
                maxDepth: maxDecodingDepth)
            return try decoder.unbox(value, as: type, [])
        }
    }
}
