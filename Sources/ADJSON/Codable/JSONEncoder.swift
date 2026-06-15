import ADJSONCore
public import Foundation

extension ADJSON {
    /// Drop-in replacement for `Foundation.JSONEncoder`. Reference as
    /// `ADJSON.JSONEncoder` where Foundation is also imported.
    public struct JSONEncoder {
        public var userInfo: [CodingUserInfoKey: Any] = [:]
        /// Serialization profile. Default `.rfc8259` (strict); `.javaScript` for `JSON.stringify`
        /// number/non-finite parity. `keyOrder: .sorted` and `prettyPrinted` are honored on the
        /// Codable path by re-serializing through `JSONValue`. `nilStrategy: .null` cannot be (the
        /// streaming encoder never sees `encodeIfPresent`-omitted nils) and makes `encode` throw.
        public var options: JSONEncodingOptions = .rfc8259
        /// Foundation `.prettyPrinted` parity: when set (or via `options.prettyPrinted`), output is
        /// indented. Sorted keys (`options.keyOrder == .sorted`) and pretty output are produced by
        /// re-serializing through the `JSONValue` model (which canonicalizes integral doubles to
        /// Foundation's `2`, vs the compact path's `2.0`).
        public var prettyPrinted: Bool = false
        /// How `Date` values are encoded (default `.deferredToDate`, matching Foundation).
        public var dateEncodingStrategy: DateEncodingStrategy = .deferredToDate
        /// How `Data` values are encoded (default `.base64`, matching Foundation).
        public var dataEncodingStrategy: DataEncodingStrategy = .base64
        /// How `CodingKey`s are converted to JSON keys (default `.useDefaultKeys`).
        public var keyEncodingStrategy: KeyEncodingStrategy = .useDefaultKeys
        /// Maximum native recursion depth for the (necessarily recursive) Codable encode. Past this,
        /// encoding throws `EncodingError.invalidValue` instead of overflowing the call stack — so a
        /// recursive or self-referential `Encodable` fails closed. Symmetric with
        /// ``JSONDecoder/maxDecodingDepth``; the default **2048** is sized for the ~8 MB main thread
        /// (lower it when encoding untrusted graphs on a small-stack worker thread).
        public var maxEncodingDepth: Int = 2048

        public init() {}

        private var strategies: EncodeStrategies {
            EncodeStrategies(date: dateEncodingStrategy, data: dataEncodingStrategy, key: keyEncodingStrategy)
        }

        public func encode<T: Encodable>(_ value: T) throws -> Data {
            let bytes = try encodeToBytes(value)
            let data = Data(bytes)
            EncoderBufferPool.recycle(bytes)
            return data
        }

        // Takes the monomorphic fast path when the value opts in (incl. arrays,
        // optionals, and string-keyed dictionaries of fast elements) — writing into a
        // value-type buffer with no class indirection; otherwise the generic streaming
        // encoder over the class-backed writer.
        public func encodeToBytes<T: Encodable>(_ value: T) throws -> [UInt8] {
            // `nilStrategy: .null` can't be honored on this path: synthesized encoders omit nil
            // optionals via `encodeIfPresent`, so the encoder never sees them to emit `null`. Reject
            // loudly rather than silently produce nil-omitting output.
            if options.nilStrategy != .omit {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: [],
                        debugDescription:
                            "ADJSON.JSONEncoder can't honor nilStrategy: .null on the Codable path (omitted "
                            + "nils are never observed); use JSONValue.encoded(options:) instead."))
            }
            // Sorted keys / pretty output aren't expressible in the single-pass streaming writer, so
            // stream compact, then re-serialize through the `JSONValue` model (which sorts + indents).
            var emitOptions = options
            emitOptions.prettyPrinted = options.prettyPrinted || prettyPrinted
            if emitOptions.keyOrder == .sorted || emitOptions.prettyPrinted {
                let compact = try encodeCompact(value)
                let model = try JSONValue(ADJSON.parse(compact).root)
                return try model.encodedBytes(options: emitOptions)
            }
            return try encodeCompact(value)
        }

        // Takes the monomorphic fast path when the value opts in (incl. arrays, optionals, and
        // string-keyed dictionaries of fast elements) — writing into a value-type buffer with no
        // class indirection; otherwise the generic streaming encoder over the class-backed writer.
        // `encodeValue` intercepts a top-level `Date`/`Data` by type and applies its strategy.
        private func encodeCompact<T: Encodable>(_ value: T) throws -> [UInt8] {
            // A key strategy must transform every object key, which only the generic `member` path
            // does — so skip the fast writer entirely when one is set.
            var keyStrategyActive = true
            if case .useDefaultKeys = keyEncodingStrategy { keyStrategyActive = false }
            if !keyStrategyActive, let fast = value as? any ADJSONFastEncodable {
                var w = _JSONByteWriter(
                    adopting: EncoderBufferPool.take(), options: options, maxDepth: maxEncodingDepth)
                do {
                    try fast.__adjsonEncode(into: &w)
                } catch {
                    EncoderBufferPool.recycle(w.bytes)
                    throw error
                }
                return w.bytes
            }
            let writer = JSONWriter(adopting: EncoderBufferPool.take())
            let state = EncodeState(writer, options: options, strategies: strategies, maxEncodeDepth: maxEncodingDepth)
            do {
                try state.encodeValue(value)
            } catch {
                EncoderBufferPool.recycle(writer.bytes)
                throw error
            }
            state.closeDownTo(0)
            return writer.bytes
        }
    }
}
