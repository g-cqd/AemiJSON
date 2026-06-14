// Single source of truth for low-level JSON byte emission. Shared by the class
// `JSONWriter` (generic streaming encoder), the value-type `JSONByteWriter` (the
// `@JSONCodable` fast path), and schema rendering — so string escaping and integer
// formatting exist in exactly one place rather than drifting across copies. The routines
// are `@inlinable` so the fast path still inlines them across the module boundary.
@usableFromInline
enum JSONOutput {
    @inlinable
    static func appendNull(to bytes: inout [UInt8]) {
        bytes.append(0x6E)
        bytes.append(0x75)
        bytes.append(0x6C)
        bytes.append(0x6C)
    }

    @inlinable
    static func appendBool(_ v: Bool, to bytes: inout [UInt8]) {
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

    @inlinable
    static func appendInteger<T: FixedWidthInteger>(_ v: T, to bytes: inout [UInt8]) {
        if v == 0 {
            bytes.append(0x30)
            return
        }
        if T.isSigned && v < 0 { bytes.append(0x2D) }
        appendMagnitude(v.magnitude, to: &bytes)
    }

    @inlinable
    static func appendMagnitude<U: UnsignedInteger & FixedWidthInteger>(_ value: U, to bytes: inout [UInt8]) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 40) { buf in
            var n = value
            var idx = 40
            repeat {
                idx -= 1
                buf[idx] = 0x30 + UInt8(truncatingIfNeeded: n % 10)
                n /= 10
            } while n > 0
            bytes.append(contentsOf: buf[idx..<40])
        }
    }

    /// Appends `"…"` with RFC 8259 minimal escaping: `"`, `\`, and the C0 controls
    /// (`\n \r \t \b \f` short forms, everything else `\u00XX`). Bytes ≥ 0x20 other than
    /// `"`/`\` are copied verbatim in runs, so well-formed UTF-8 passes through untouched.
    @inlinable
    static func appendString(_ s: String, to bytes: inout [UInt8]) {
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
                    appendEscape(b, to: &bytes)
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

    @inlinable
    static func appendEscape(_ b: UInt8, to bytes: inout [UInt8]) {
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
            bytes.append(hexDigit(b >> 4))
            bytes.append(hexDigit(b & 0xF))
        }
    }

    @inlinable
    static func hexDigit(_ v: UInt8) -> UInt8 {
        v < 10 ? 0x30 + v : 0x61 + (v - 10)
    }
}
