import Foundation

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
    static func appendString(_ s: String, to bytes: inout [UInt8], escapeSlashes: Bool = false) {
        bytes.append(0x22)
        var str = s
        str.withUTF8 { buf in
            guard let p = buf.baseAddress else { return }
            let n = buf.count
            var runStart = 0
            var i = 0
            while i < n {
                let b = p[i]
                if b < 0x20 || b == 0x22 || b == 0x5C || (escapeSlashes && b == 0x2F) {
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
        case 0x2F: bytes.append(0x2F)
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

    /// Appends a finite `Double` formatted per ECMA-262 §6.1.6.1.20 `Number::toString` — i.e. what
    /// JavaScript `JSON.stringify` emits, which differs from `Double.description` (integral doubles
    /// lose the trailing `.0`, `-0` becomes `0`, exponents aren't zero-padded, and the
    /// decimal↔exponential threshold is `n > 21` / `n ≤ -6`). It reuses Swift's shortest
    /// round-trippable digits (from `description`) and only re-renders their placement. The caller
    /// must have already handled non-finite values.
    @usableFromInline
    static func appendECMANumber(_ v: Double, to bytes: inout [UInt8]) {
        let d = Array(v.description.utf8)  // shortest round-trippable, ASCII
        var pos = 0
        let negative = d.first == 0x2D
        if negative { pos = 1 }

        // Split off an explicit exponent (`e±NN`), if any.
        var exp = 0
        var mantEnd = d.count
        var j = pos
        while j < d.count {
            if d[j] == 0x65 || d[j] == 0x45 {
                mantEnd = j
                var ei = j + 1
                var eNeg = false
                if ei < d.count, d[ei] == 0x2B || d[ei] == 0x2D {
                    eNeg = d[ei] == 0x2D
                    ei += 1
                }
                var e = 0
                while ei < d.count {
                    e = e * 10 + Int(d[ei] - 0x30)
                    ei += 1
                }
                exp = eNeg ? -e : e
                break
            }
            j += 1
        }

        // Gather the significant digits and the decimal-point position `pointPos` (digits before it).
        var dotAt = -1
        var t = pos
        while t < mantEnd {
            if d[t] == 0x2E {
                dotAt = t
                break
            }
            t += 1
        }
        var digits = [UInt8]()
        digits.reserveCapacity(mantEnd - pos)
        var pointPos: Int
        if dotAt >= 0 {
            for x in pos..<dotAt { digits.append(d[x]) }
            for x in (dotAt + 1)..<mantEnd { digits.append(d[x]) }
            pointPos = dotAt - pos
        } else {
            for x in pos..<mantEnd { digits.append(d[x]) }
            pointPos = mantEnd - pos
        }
        pointPos += exp

        // Normalize to shortest significant digits `[start, end)`, adjusting `pointPos`.
        var start = 0
        while start < digits.count, digits[start] == 0x30 {
            start += 1
            pointPos -= 1
        }
        var end = digits.count
        while end > start, digits[end - 1] == 0x30 { end -= 1 }
        if start >= end {  // value is zero (including -0)
            bytes.append(0x30)
            return
        }

        let k = end - start
        let n = pointPos
        if negative { bytes.append(0x2D) }
        if k <= n, n <= 21 {
            for x in start..<end { bytes.append(digits[x]) }
            for _ in 0..<(n - k) { bytes.append(0x30) }
        } else if n > 0, n <= 21 {
            for x in start..<(start + n) { bytes.append(digits[x]) }
            bytes.append(0x2E)
            for x in (start + n)..<end { bytes.append(digits[x]) }
        } else if n > -6, n <= 0 {
            bytes.append(0x30)
            bytes.append(0x2E)
            for _ in 0..<(-n) { bytes.append(0x30) }
            for x in start..<end { bytes.append(digits[x]) }
        } else {
            bytes.append(digits[start])
            if k > 1 {
                bytes.append(0x2E)
                for x in (start + 1)..<end { bytes.append(digits[x]) }
            }
            bytes.append(0x65)  // 'e'
            let e = n - 1
            bytes.append(e >= 0 ? 0x2B : 0x2D)
            appendInteger(abs(e), to: &bytes)
        }
    }

    /// Emits a `Double` per the encoding `options`: `numberFormat` chooses Swift-shortest
    /// (`Double.description`) vs ECMA-262, and `nonFinite` chooses throw / `null` / string-literal.
    /// The single source of truth for the Codable encode paths (matches their current
    /// `Double.description` output under the `.rfc8259` default).
    @usableFromInline
    static func appendDouble(_ v: Double, options: JSONEncodingOptions, to bytes: inout [UInt8]) throws {
        guard v.isFinite else {
            switch options.nonFinite {
            case .throw:
                throw EncodingError.invalidValue(
                    v, .init(codingPath: [], debugDescription: "Non-finite \(v) cannot be encoded as JSON"))
            case .null:
                appendNull(to: &bytes)
            case .stringLiterals(let pos, let neg, let nan):
                appendString(v.isNaN ? nan : (v > 0 ? pos : neg), to: &bytes, escapeSlashes: options.escapeSlashes)
            }
            return
        }
        switch options.numberFormat {
        case .ecma262: appendECMANumber(v, to: &bytes)
        case .swiftShortest: bytes.append(contentsOf: v.description.utf8)
        }
    }
}
