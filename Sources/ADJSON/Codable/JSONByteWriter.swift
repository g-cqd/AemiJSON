/// Value-type byte buffer for the fast encode path. Threaded `inout` through
/// `__adjsonEncode`, so macro-generated code in the user's module writes JSON with no
/// class indirection. `@inlinable` so those writes inline across the module boundary.
public struct JSONByteWriter {
    @usableFromInline var bytes: [UInt8]
    @usableFromInline var options: JSONEncodingOptions

    @inlinable public init(capacity: Int = 0, options: JSONEncodingOptions = .rfc8259) {
        bytes = []
        if capacity > 0 { bytes.reserveCapacity(capacity) }
        self.options = options
    }

    init(adopting buffer: [UInt8], options: JSONEncodingOptions = .rfc8259) {
        bytes = buffer
        self.options = options
    }

    @inlinable public mutating func beginObject() { bytes.append(0x7B) }
    @inlinable public mutating func endObject() { bytes.append(0x7D) }
    @inlinable public mutating func beginArray() { bytes.append(0x5B) }
    @inlinable public mutating func endArray() { bytes.append(0x5D) }
    @inlinable public mutating func comma() { bytes.append(0x2C) }

    @inlinable public mutating func null() { JSONOutput.appendNull(to: &bytes) }

    @inlinable public mutating func bool(_ v: Bool) { JSONOutput.appendBool(v, to: &bytes) }

    /// A statically-known object key: `"key":`.
    @inlinable public mutating func key(_ k: StaticString) {
        bytes.append(0x22)
        k.withUTF8Buffer { bytes.append(contentsOf: $0) }
        bytes.append(0x22)
        bytes.append(0x3A)
    }

    /// A runtime object key (escaped) followed by `:`. Used for `Dictionary` keys.
    @inlinable public mutating func dynamicKey(_ k: String) {
        JSONOutput.appendString(k, to: &bytes)
        bytes.append(0x3A)
    }

    @inlinable public mutating func string(_ v: String) { JSONOutput.appendString(v, to: &bytes) }

    @inlinable public mutating func integer<T: FixedWidthInteger>(_ v: T) {
        JSONOutput.appendInteger(v, to: &bytes)
    }

    @inlinable public mutating func double(_ v: Double) throws {
        try JSONOutput.appendDouble(v, options: options, to: &bytes)
    }

    @inlinable public mutating func encode<T: Encodable>(_ v: T) throws {
        if let fast = v as? any ADJSONFastEncodable {
            try fast.__adjsonEncode(into: &self)
        } else {
            try encodeGeneric(v)
        }
    }

    /// Generic fallback: stream into the class buffer over the moved-out bytes, then move
    /// back. Not `@inlinable` (it touches internal encoder types), but reachable from the
    /// inlinable `encode` so generated code can call it.
    @usableFromInline mutating func encodeGeneric<T: Encodable>(_ v: T) throws {
        let writer = JSONWriter(adopting: bytes)
        bytes = []
        let state = EncodeState(writer, options: options)
        try v.encode(to: TapeEncoder(state: state))
        state.closeDownTo(0)
        bytes = writer.bytes
    }
}
