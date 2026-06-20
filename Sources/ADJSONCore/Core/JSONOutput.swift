// Single source of truth for low-level JSON byte emission. Shared by the class
// `JSONWriter` (generic streaming encoder), the value-type `_JSONByteWriter` (the
// `@JSONCodable` fast path), and schema rendering — so string escaping and integer
// formatting exist in exactly one place rather than drifting across copies. The routines
// are `@inlinable` so the fast path still inlines them across the module boundary.
//
// Number formatting (ECMA-262 / Swift-shortest / SQLite `%!.15g`) lives in the sibling
// `JSONOutput+Numbers.swift` extension to keep this type body inside the size gate.
//
// `public import`: `encodeStopMask` below is `@inlinable` and references `ADFCore.SWAR`, so ADFCore
// must be part of this module's public/inlinable surface — an internal import would make the
// referenced symbol invisible to inlinable bodies. Mirrors `KeyCompare.swift` (for `ByteCompare`).
public import ADFCore

public enum JSONOutput {
    @inlinable
    public static func appendNull(to bytes: inout [UInt8]) {
        bytes.append(0x6E)
        bytes.append(0x75)
        bytes.append(0x6C)
        bytes.append(0x6C)
    }

    @inlinable
    public static func appendBool(_ v: Bool, to bytes: inout [UInt8]) {
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
    public static func appendInteger<T: FixedWidthInteger>(_ v: T, to bytes: inout [UInt8]) {
        if v == 0 {
            bytes.append(0x30)
            return
        }
        if T.isSigned && v < 0 { bytes.append(0x2D) }
        appendMagnitude(v.magnitude, to: &bytes)
    }

    @inlinable
    public static func appendMagnitude<U: UnsignedInteger & FixedWidthInteger>(_ value: U, to bytes: inout [UInt8]) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 40) { buf in
            var n = value
            var idx = 40
            repeat {
                idx -= 1
                buf[idx] = 0x30 + UInt8(truncatingIfNeeded: n % 10)
                n /= 10
            } while n > 0
            bytes.append(contentsOf: buf[idx ..< 40])
        }
    }

    /// Appends a newline (`\n`) followed by the pretty-print indent `unit` repeated `level` times.
    /// One definition shared by every serializer — the eager `JSONValue` walk, the lazy `JSON`
    /// cursor, and the streaming `JSONWriter` — so the indent can't drift between them.
    @inlinable
    public static func appendNewlineIndent(to bytes: inout [UInt8], level: Int, unit: [UInt8]) {
        bytes.append(0x0A)
        guard !unit.isEmpty else { return }
        for _ in 0 ..< level { bytes.append(contentsOf: unit) }
    }

    /// Appends `"…"` with RFC 8259 minimal escaping: `"`, `\`, and the C0 controls
    /// (`\n \r \t \b \f` short forms, everything else `\u00XX`). Bytes ≥ 0x20 other than
    /// `"`/`\` are copied verbatim in runs, so well-formed UTF-8 passes through untouched.
    ///
    /// `escapeHTMLUnsafe` additionally escapes the characters unsafe to embed in HTML/`<script>`:
    /// `<`, `>`, `&` (as `<`/`>`/`&`) and the JS line/paragraph separators U+2028 /
    /// U+2029 (as ` `/` `). Off by default; the checks short-circuit so the default path is
    /// unchanged.
    /// SWAR escape stop-mask for ``appendString``: `0x80` in each byte that must be escaped on the
    /// default / `escapeSlashes` profile — a control (`< 0x20`), `"`, `\` (and `/` when escaping
    /// slashes). Non-ASCII is intentionally NOT flagged (well-formed UTF-8 is copied verbatim on
    /// encode), which is the one term that differs from the parser's `stringStopMask`.
    @inlinable @inline(__always)
    static func encodeStopMask(_ v: UInt64, escapeSlashes: Bool) -> UInt64 {
        let m = SWAR.lessThan(v, 0x20) | SWAR.equals(v, 0x22) | SWAR.equals(v, 0x5C)
        return escapeSlashes ? m | SWAR.equals(v, 0x2F) : m
    }

    @inlinable
    public static func appendString(
        _ s: String, to bytes: inout [UInt8], escapeSlashes: Bool = false, escapeHTMLUnsafe: Bool = false
    ) {
        bytes.append(0x22)
        var str = s
        str.withUTF8 { buf in
            guard let p = buf.baseAddress else { return }
            let n = buf.count
            var runStart = 0
            var i = 0
            while i < n {
                // SWAR fast-forward over clean runs (8 bytes/step) on the default / escapeSlashes
                // profile, stopping at a control, `"`, `\` (or `/`); non-ASCII is copied verbatim. The
                // HTML-safe mode skips it — that path also needs the `<`/`>`/`&` and 3-byte sequence checks.
                if !escapeHTMLUnsafe {
                    while i + 8 <= n {
                        let word = UInt64(littleEndian: UnsafeRawPointer(p + i).loadUnaligned(as: UInt64.self))
                        let mask = encodeStopMask(word, escapeSlashes: escapeSlashes)
                        if mask == 0 {
                            i += 8
                            continue
                        }
                        i += mask.trailingZeroBitCount >> 3
                        break
                    }
                    guard i < n else { break }
                }
                let b = p[i]
                // U+2028 / U+2029 are 3-byte sequences (E2 80 A8/A9), so they need a UTF-8-aware branch
                // rather than a single-byte test — taken only under HTML-safe escaping.
                if escapeHTMLUnsafe, b == 0xE2, i + 2 < n, p[i + 1] == 0x80, p[i + 2] == 0xA8 || p[i + 2] == 0xA9 {
                    if i > runStart {
                        bytes.append(contentsOf: UnsafeBufferPointer(start: p + runStart, count: i - runStart))
                    }
                    bytes.append(contentsOf: [0x5C, 0x75, 0x32, 0x30, 0x32, p[i + 2] == 0xA8 ? 0x38 : 0x39])  //  /9
                    i += 3
                    runStart = i
                    continue
                }
                let htmlUnsafe = escapeHTMLUnsafe && (b == 0x3C || b == 0x3E || b == 0x26)  // < > &
                if b < 0x20 || b == 0x22 || b == 0x5C || (escapeSlashes && b == 0x2F) || htmlUnsafe {
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
    public static func appendEscape(_ b: UInt8, to bytes: inout [UInt8]) {
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
    public static func hexDigit(_ v: UInt8) -> UInt8 {
        v < 10 ? 0x30 + v : 0x61 + (v - 10)
    }
}
