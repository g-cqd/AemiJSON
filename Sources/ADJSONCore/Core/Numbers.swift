// Number materialization over a byte range; to be replaced by Eisel-Lemire in a later phase.
public enum JSONNumber {
    // `Double(_:)` parses with fixed C-locale semantics, unlike libc `strtod`, which honours the
    // host `LC_NUMERIC` and would misread "1.5" as 1.0 under a comma-decimal locale (set by the
    // process or an interop library via `setlocale`). The scanner has already validated the
    // number's shape, so this only fails on out-of-range magnitudes, which round to ±inf exactly
    // as `strtod` did. Short numbers (≤15 UTF-8 bytes — the common case) use the inline
    // small-string buffer, so no heap allocation occurs on the hot path.
    @inline(__always)
    public static func parseDouble(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> Double {
        let s = String(decoding: UnsafeBufferPointer(start: p + offset, count: length), as: UTF8.self)
        return Double(s) ?? .nan
    }

    // Generic integer parse with correct overflow handling for any width, signed or
    // unsigned (negatives accumulate downward so Int.min and UInt.max both work).
    @inline(__always)
    public static func parseInteger<T: FixedWidthInteger>(
        _ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int, _ type: T.Type
    ) -> T? {
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
}
