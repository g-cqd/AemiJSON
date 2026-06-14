import Foundation

extension ADJSON {
    /// Drop-in replacement for `Foundation.JSONEncoder`. Reference as
    /// `ADJSON.JSONEncoder` where Foundation is also imported.
    public struct JSONEncoder {
        public var userInfo: [CodingUserInfoKey: Any] = [:]

        public init() {}

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
            if let fast = value as? ADJSONFastEncodable {
                var w = JSONByteWriter(adopting: EncoderBufferPool.take())
                try fast.__adjsonEncode(into: &w)
                return w.bytes
            }
            let writer = JSONWriter(adopting: EncoderBufferPool.take())
            let state = EncodeState(writer)
            try value.encode(to: TapeEncoder(state: state))
            state.closeDownTo(0)
            return writer.bytes
        }
    }
}
