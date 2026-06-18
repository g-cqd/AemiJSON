import ADJSONCore
public import Foundation

extension ADJSON {
    /// Drop-in replacement for `Foundation.JSONEncoder`. Reference as
    /// `ADJSON.JSONEncoder` where Foundation is also imported.
    public struct JSONEncoder {
        public var userInfo: [CodingUserInfoKey: Any] = [:]
        /// Serialization profile. Default `.rfc8259` (strict); `.javaScript` for `JSON.stringify`
        /// number/non-finite parity. `prettyPrinted` streams in a single pass; `keyOrder: .sorted` is
        /// honored on the Codable path by re-serializing through the parsed tape (the streaming writer
        /// can't reorder members). `nilStrategy: .null` cannot be (the streaming encoder never sees
        /// `encodeIfPresent`-omitted nils) and makes `encode` throw.
        public var options: JSONEncodingOptions = .rfc8259
        /// Foundation `.prettyPrinted` parity: when set (or via `options.prettyPrinted`), output is
        /// indented. Pretty output in declaration order streams in a single pass; sorted output still
        /// re-serializes through the parsed tape (the streaming writer can't reorder members). All
        /// three share the streaming number format — an integral `Double` stays `2.0` (a bare `2` comes
        /// only from an integer-typed value), consistent across compact, pretty, and sorted.
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
            let pretty = options.prettyPrinted || prettyPrinted
            // Sorted keys can't be produced in a single streaming pass (the writer can't reorder an
            // object's members), so they stream compact, then re-emit sorted straight from the parsed
            // tape — `emitOptions` carries pretty into that re-emit. Pretty output in declaration order,
            // by contrast, streams in one pass (no parse, no re-emit).
            if options.keyOrder == .sorted {
                var emitOptions = options
                emitOptions.prettyPrinted = pretty
                let compact = try encodeStreaming(value, pretty: false)
                return try ADJSON.parse(compact).root.encodedBytes(options: emitOptions)
            }
            return try encodeStreaming(value, pretty: pretty)
        }

        // Streams one pass straight into the buffer (compact, or pretty when `pretty`). Takes the
        // monomorphic fast path when the value opts in (incl. arrays, optionals, and string-keyed
        // dictionaries of fast elements) — a value-type buffer with no class indirection — otherwise
        // the generic streaming encoder over the class-backed writer. `encodeValue` intercepts a
        // top-level `Date`/`Data` by type and applies its strategy.
        private func encodeStreaming<T: Encodable>(_ value: T, pretty: Bool) throws -> [UInt8] {
            // A key strategy must transform every object key, which only the generic `member` path
            // does — so skip the fast writer when one is set. The fast writer is also compact-only, so
            // pretty output skips it the same way and streams through `EncodeState`.
            var keyStrategyActive = true
            if case .useDefaultKeys = keyEncodingStrategy { keyStrategyActive = false }
            if !pretty, !keyStrategyActive, let fast = value as? any ADJSONFastEncodable {
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
            writer.escapeSlashes = options.escapeSlashes
            writer.escapeHTMLUnsafe = options.escapeHTMLUnsafe
            let state = EncodeState(
                writer, options: options, strategies: strategies, maxEncodeDepth: maxEncodingDepth, pretty: pretty)
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
