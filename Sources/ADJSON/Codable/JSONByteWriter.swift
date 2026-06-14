import Foundation

/// Value-type byte buffer for the fast encode path. Threaded `inout` through
/// `__adjsonEncode`, so macro-generated code in the user's module writes JSON with no
/// class indirection. `@inlinable` so those writes inline across the module boundary.
public struct JSONByteWriter {
    @usableFromInline var bytes: [UInt8]

    @inlinable public init(capacity: Int = 0) {
        bytes = []
        if capacity > 0 { bytes.reserveCapacity(capacity) }
    }

    init(adopting buffer: [UInt8]) { bytes = buffer }

    @inlinable public mutating func beginObject() { bytes.append(0x7B) }
    @inlinable public mutating func endObject() { bytes.append(0x7D) }
    @inlinable public mutating func beginArray() { bytes.append(0x5B) }
    @inlinable public mutating func endArray() { bytes.append(0x5D) }
    @inlinable public mutating func comma() { bytes.append(0x2C) }

    @inlinable public mutating func null() {
        bytes.append(0x6E)
        bytes.append(0x75)
        bytes.append(0x6C)
        bytes.append(0x6C)
    }

    @inlinable public mutating func bool(_ v: Bool) {
        if v {
            bytes.append(0x74)
            bytes.append(0x72)
            bytes.append(0x75)
            bytes.append(0x65)
        } else {
            bytes.append(0x66)
            bytes.append(0x61)
            bytes.append(0x6C)
            bytes.append(0x73)
            bytes.append(0x65)
        }
    }

    /// A statically-known object key: `"key":`.
    @inlinable public mutating func key(_ k: StaticString) {
        bytes.append(0x22)
        k.withUTF8Buffer { bytes.append(contentsOf: $0) }
        bytes.append(0x22)
        bytes.append(0x3A)
    }

    /// A runtime object key (escaped) followed by `:`. Used for `Dictionary` keys.
    @inlinable public mutating func dynamicKey(_ k: String) {
        appendString(k)
        bytes.append(0x3A)
    }

    @inlinable public mutating func string(_ v: String) { appendString(v) }

    @inlinable public mutating func integer<T: FixedWidthInteger>(_ v: T) {
        if v == 0 {
            bytes.append(0x30)
            return
        }
        if T.isSigned && v < 0 { bytes.append(0x2D) }
        appendMagnitude(v.magnitude)
    }

    @inlinable public mutating func double(_ v: Double) throws {
        guard v.isFinite else {
            throw EncodingError.invalidValue(
                v, .init(codingPath: [], debugDescription: "Non-finite \(v) cannot be encoded as JSON"))
        }
        bytes.append(contentsOf: v.description.utf8)
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
        let state = EncodeState(writer)
        try v.encode(to: TapeEncoder(state: state))
        state.closeDownTo(0)
        bytes = writer.bytes
    }

    @usableFromInline mutating func appendMagnitude<U: UnsignedInteger & FixedWidthInteger>(_ value: U) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 40) { buf in
            var n = value
            var idx = 40
            while n > 0 {
                idx -= 1
                buf[idx] = 0x30 + UInt8(truncatingIfNeeded: n % 10)
                n /= 10
            }
            bytes.append(contentsOf: buf[idx..<40])
        }
    }

    @usableFromInline mutating func appendString(_ s: String) {
        bytes.append(0x22)
        var str = s
        str.withUTF8 { buf in
            guard let p = buf.baseAddress else { return }
            let n = buf.count
            var runStart = 0
            var i = 0
            while i < n {
                let b = p[i]
                if b < 0x20 || b == 0x22 || b == 0x5C {
                    if i > runStart {
                        bytes.append(contentsOf: UnsafeBufferPointer(start: p + runStart, count: i - runStart))
                    }
                    appendEscape(b)
                    i += 1
                    runStart = i
                } else {
                    i += 1
                }
            }
            if i > runStart {
                bytes.append(contentsOf: UnsafeBufferPointer(start: p + runStart, count: i - runStart))
            }
        }
        bytes.append(0x22)
    }

    @usableFromInline mutating func appendEscape(_ b: UInt8) {
        bytes.append(0x5C)
        switch b {
        case 0x22: bytes.append(0x22)
        case 0x5C: bytes.append(0x5C)
        case 0x0A: bytes.append(0x6E)
        case 0x0D: bytes.append(0x72)
        case 0x09: bytes.append(0x74)
        case 0x08: bytes.append(0x62)
        case 0x0C: bytes.append(0x66)
        default:
            bytes.append(0x75)
            bytes.append(0x30)
            bytes.append(0x30)
            bytes.append(b >> 4 < 10 ? 0x30 + (b >> 4) : 0x61 + (b >> 4) - 10)
            bytes.append(b & 0xF < 10 ? 0x30 + (b & 0xF) : 0x61 + (b & 0xF) - 10)
        }
    }
}
