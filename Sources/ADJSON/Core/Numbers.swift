import Foundation

// Number materialization over a byte range. Doubles currently use libc strtod on a
// stack copy (correct, no overrun); to be replaced by Eisel-Lemire in a later phase.

@inline(__always)
@usableFromInline
func adParseDouble(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> Double {
    if length < 32 {
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 33) { buf in
            guard let base = buf.baseAddress else { return .nan }
            memcpy(base, p + offset, length)
            base[length] = 0
            return strtod(base, nil)
        }
    }
    let s = String(decoding: UnsafeBufferPointer(start: p + offset, count: length), as: UTF8.self)
    return Double(s) ?? .nan
}

// Generic integer parse with correct overflow handling for any width, signed or
// unsigned (negatives accumulate downward so Int.min and UInt.max both work).
@inline(__always)
@usableFromInline
func adParseInteger<T: FixedWidthInteger>(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int, _ type: T.Type) -> T?
{
    var idx = offset
    let end = offset + length
    guard idx < end else { return nil }
    var neg = false
    if p[idx] == 0x2D {
        neg = true
        idx += 1
        if !T.isSigned { return nil }
    } else if p[idx] == 0x2B {
        idx += 1
    }
    guard idx < end else { return nil }
    var v: T = 0
    let ten = T(10)
    while idx < end {
        let c = p[idx]
        guard c >= 0x30 && c <= 0x39 else { return nil }
        let d = T(truncatingIfNeeded: c - 0x30)
        let (m, o1) = v.multipliedReportingOverflow(by: ten)
        guard !o1 else { return nil }
        if neg {
            let (s, o2) = m.subtractingReportingOverflow(d)
            guard !o2 else { return nil }
            v = s
        } else {
            let (a, o2) = m.addingReportingOverflow(d)
            guard !o2 else { return nil }
            v = a
        }
        idx += 1
    }
    return v
}
