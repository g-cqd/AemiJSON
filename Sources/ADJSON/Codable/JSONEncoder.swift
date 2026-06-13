import Foundation

extension ADJSON {
    /// Drop-in replacement for `Foundation.JSONEncoder`. Reference as
    /// `ADJSON.JSONEncoder` where Foundation is also imported.
    public struct JSONEncoder {
        public var userInfo: [CodingUserInfoKey: Any] = [:]

        public init() {}

        public func encode<T: Encodable>(_ value: T) throws -> Data {
            let writer = JSONWriter(adopting: EncoderBufferPool.take())
            try write(value, into: writer)
            let data = Data(writer.bytes)
            EncoderBufferPool.recycle(writer.bytes)
            return data
        }

        public func encodeToBytes<T: Encodable>(_ value: T) throws -> [UInt8] {
            let writer = JSONWriter(capacity: 1024)
            try write(value, into: writer)
            return writer.bytes
        }

        // Takes the monomorphic fast path when the value opts in (incl. arrays,
        // optionals, and string-keyed dictionaries of fast elements); otherwise the
        // generic streaming encoder.
        private func write<T: Encodable>(_ value: T, into writer: JSONWriter) throws {
            if let fast = value as? ADJSONFastEncodable {
                try fast.__adjsonEncode(into: _FastEncodeWriter(writer))
            } else {
                let state = EncodeState(writer)
                try value.encode(to: TapeEncoder(state: state))
                state.closeDownTo(0)
            }
        }
    }
}
