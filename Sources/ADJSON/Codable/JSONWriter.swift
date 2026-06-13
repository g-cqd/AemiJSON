import Foundation

// A growable byte buffer with JSON formatting helpers. Reference type so the
// streaming encoder and the macro fast path can share one buffer as they recurse.
// Numbers are written straight into the buffer (no intermediate String for ints).
final class JSONWriter {
    var bytes: [UInt8]

    init(capacity: Int = 0) {
        bytes = []
        if capacity > 0 { bytes.reserveCapacity(capacity) }
    }

    init(adopting buffer: [UInt8]) {
        bytes = buffer
        bytes.reserveCapacity(max(bytes.capacity, 1024))
    }

    @inline(__always) func byte(_ b: UInt8) { bytes.append(b) }

    @inline(__always) func raw(_ lit: StaticString) {
        lit.withUTF8Buffer { bytes.append(contentsOf: $0) }
    }

    func writeNull() {
        bytes.append(0x6E)
        bytes.append(0x75)
        bytes.append(0x6C)
        bytes.append(0x6C)
    }

    func writeBool(_ v: Bool) {
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

    @inline(__always) func writeInteger<T: FixedWidthInteger>(_ v: T) {
        if v == 0 {
            bytes.append(0x30)
            return
        }
        if T.isSigned && v < 0 { bytes.append(0x2D) }
        writeMagnitude(v.magnitude)
    }

    @inline(__always) private func writeMagnitude<U: UnsignedInteger & FixedWidthInteger>(_ value: U) {
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

    func writeDouble(_ v: Double) { bytes.append(contentsOf: v.description.utf8) }
    func writeFloat(_ v: Float) { bytes.append(contentsOf: v.description.utf8) }

    // "key":
    func writeKey(_ s: String) {
        writeString(s)
        bytes.append(0x3A)
    }

    func writeString(_ s: String) {
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

    @inline(__always) private func appendEscape(_ b: UInt8) {
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

    @inline(__always) private func hexDigit(_ v: UInt8) -> UInt8 {
        v < 10 ? 0x30 + v : 0x61 + (v - 10)
    }
}
