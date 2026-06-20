// Number formatting for `JSONOutput` — the ECMA-262, Swift-shortest, and SQLite `%!.15g` real
// renderers (and the shared shortest-digit gather they build on). Split out of `JSONOutput.swift`
// to keep each type body inside the size gate; the routines stay `JSONOutput` statics (same type,
// same `@inlinable` surface) so call sites are unchanged.
//
// The platform libc import below is for `vsnprintf` (the SQLite `%!.15g` number format only); it is
// not Foundation, so the core stays Foundation-free.
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

extension JSONOutput {
    /// Parse Swift's shortest decimal (`Double.description`) for a **finite** `v` into its significant
    /// digits and decimal-point position, then invoke `body` — the one place the encoders source
    /// shortest digits, shared by ``appendECMANumber(_:to:)`` and ``JSONShortest/appendShortest(_:to:)``
    /// under different placement rules. `digits` are the significant digits (no leading/trailing zeros);
    /// `pointPos` is how many of them fall before the decimal point (value = digits × 10^(pointPos −
    /// count)); `digits.count == 0` signals zero. `description` is the only allocation (Swift's
    /// correctly-rounded shortest digits, ASCII, locale-independent); the gather uses a 24-byte stack
    /// span — a finite double prints in ≤ 24 ASCII bytes. `body` is non-escaping (runs inside the span).
    static func withShortestDigits(
        _ v: Double, _ body: (_ negative: Bool, _ digits: UnsafeBufferPointer<UInt8>, _ pointPos: Int) -> Void
    ) {
        var desc = v.description
        desc.withUTF8 { d in
            let count = d.count
            var pos = 0
            let negative = d.first == 0x2D
            if negative { pos = 1 }

            // Split off an explicit exponent (`e±NN`), if any.
            var exp = 0
            var mantEnd = count
            var j = pos
            while j < count {
                if d[j] == 0x65 || d[j] == 0x45 {
                    mantEnd = j
                    var ei = j + 1
                    var eNeg = false
                    if ei < count, d[ei] == 0x2B || d[ei] == 0x2D {
                        eNeg = d[ei] == 0x2D
                        ei += 1
                    }
                    var e = 0
                    while ei < count {
                        e = e * 10 + Int(d[ei] - 0x30)
                        ei += 1
                    }
                    exp = eNeg ? -e : e
                    break
                }
                j += 1
            }

            // Locate the decimal point within the mantissa.
            var dotAt = -1
            var t = pos
            while t < mantEnd {
                if d[t] == 0x2E {
                    dotAt = t
                    break
                }
                t += 1
            }

            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 24) { digits in
                // `capacity: 24 > 0`, so the temporary buffer always has a base address.
                guard let digitsBase = digits.baseAddress else { return }
                // Gather the significant digits and the decimal-point position `pointPos`.
                var dc = 0
                var pointPos: Int
                if dotAt >= 0 {
                    for x in pos ..< dotAt {
                        digits[dc] = d[x]
                        dc += 1
                    }
                    for x in (dotAt + 1) ..< mantEnd {
                        digits[dc] = d[x]
                        dc += 1
                    }
                    pointPos = dotAt - pos
                } else {
                    for x in pos ..< mantEnd {
                        digits[dc] = d[x]
                        dc += 1
                    }
                    pointPos = mantEnd - pos
                }
                pointPos += exp

                // Normalize to shortest significant digits `[start, end)`, adjusting `pointPos`.
                var start = 0
                while start < dc, digits[start] == 0x30 {
                    start += 1
                    pointPos -= 1
                }
                var end = dc
                while end > start, digits[end - 1] == 0x30 { end -= 1 }
                // The buffer addresses the stack `digits` allocation, valid only for this `body` call —
                // `body` must consume it inline and must not store or return it (it dangles after).
                body(negative, UnsafeBufferPointer(start: digitsBase + start, count: end - start), pointPos)
            }
        }
    }

    /// Appends a finite `Double` formatted per ECMA-262 §6.1.6.1.20 `Number::toString` — i.e. what
    /// JavaScript `JSON.stringify` emits, which differs from `Double.description` (integral doubles
    /// lose the trailing `.0`, `-0` becomes `0`, exponents aren't zero-padded, and the
    /// decimal↔exponential threshold is `n > 21` / `n ≤ -6`). Reuses Swift's shortest digits via
    /// ``withShortestDigits(_:_:)`` and only re-renders their placement. Caller handles non-finite.
    public static func appendECMANumber(_ v: Double, to bytes: inout [UInt8]) {
        withShortestDigits(v) { negative, digits, pointPos in
            let k = digits.count
            if k == 0 {  // zero — ECMA renders `-0` as `0`, so no sign
                bytes.append(0x30)
                return
            }
            let n = pointPos
            if negative { bytes.append(0x2D) }
            if k <= n, n <= 21 {
                for x in 0 ..< k { bytes.append(digits[x]) }
                for _ in 0 ..< (n - k) { bytes.append(0x30) }
            } else if n > 0, n <= 21 {
                for x in 0 ..< n { bytes.append(digits[x]) }
                bytes.append(0x2E)
                for x in n ..< k { bytes.append(digits[x]) }
            } else if n > -6, n <= 0 {
                bytes.append(0x30)
                bytes.append(0x2E)
                for _ in 0 ..< (-n) { bytes.append(0x30) }
                for x in 0 ..< k { bytes.append(digits[x]) }
            } else {
                bytes.append(digits[0])
                if k > 1 {
                    bytes.append(0x2E)
                    for x in 1 ..< k { bytes.append(digits[x]) }
                }
                bytes.append(0x65)  // 'e'
                let e = n - 1
                bytes.append(e >= 0 ? 0x2B : 0x2D)
                appendInteger(abs(e), to: &bytes)
            }
        }
    }

    /// The ECMAScript `Number::toString` of `v` as a `String` — the JavaScript `String(n)` /
    /// `JSON.stringify(n)` shortest-round-trip form (see ``appendECMANumber(_:to:)``). Non-finite
    /// inputs render as the ECMAScript `ToString` tokens `"NaN"`, `"Infinity"`, and `"-Infinity"`;
    /// those are language-level coercions, **not** valid JSON, so this is for host string coercion,
    /// not serialization (serialization routes non-finite values through `JSONEncodingOptions`).
    public static func ecmaNumberToString(_ v: Double) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v < 0 ? "-Infinity" : "Infinity" }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(24)  // ECMA-262 doubles render in ≤ 24 ASCII bytes
        appendECMANumber(v, to: &bytes)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Emits a **finite** `Double` per `numberFormat` — the single place the three number formats are
    /// rendered, so the streaming encoder, the `JSONValue` tree walk, the lazy `JSON` cursor, and the
    /// JS stream writer all agree byte-for-byte. A `Double` always keeps its fractional/exponent form
    /// (`2.0`, never bare `2` — a bare integer comes only from the `.int` case / integer types). The
    /// caller must have already handled non-finite values. The shortest (`.swiftShortest`) form is
    /// `Double.description` — the one spot a future direct byte formatter would replace.
    @inlinable
    public static func appendFiniteDouble(
        _ v: Double, numberFormat: JSONEncodingOptions.NumberFormat, to bytes: inout [UInt8]
    ) {
        switch numberFormat {
            case .ecma262: appendECMANumber(v, to: &bytes)
            case .swiftShortest: JSONShortest.appendShortest(v, to: &bytes)
            case .sqlitePrintfG: appendSQLitePrintfG(v, to: &bytes)
        }
    }

    /// Emits a `Double` per the encoding `options`: `nonFinite` chooses throw / `null` / string-literal,
    /// and a finite value goes through ``appendFiniteDouble(_:numberFormat:to:)``. A `Double` always
    /// renders faithfully (`2.0`, not `2`). The single source of truth for every double the encoders emit.
    public static func appendDouble(_ v: Double, options: JSONEncodingOptions, to bytes: inout [UInt8]) throws {
        guard v.isFinite else {
            switch options.nonFinite {
                case .throw:
                    throw EncodingError.invalidValue(
                        v, .init(codingPath: [], debugDescription: "Non-finite \(v) cannot be encoded as JSON"))
                case .null:
                    appendNull(to: &bytes)
                case .stringLiterals(let pos, let neg, let nan):
                    appendString(
                        v.isNaN ? nan : (v > 0 ? pos : neg), to: &bytes,
                        escapeSlashes: options.escapeSlashes, escapeHTMLUnsafe: options.escapeHTMLUnsafe)
            }
            return
        }
        appendFiniteDouble(v, numberFormat: options.numberFormat, to: &bytes)
    }

    /// Emits a **finite** `Float` per `numberFormat`. Under the default `.swiftShortest` it uses
    /// `Float.description` — the *shortest* 32-bit form (`0.1`, not the `0.10000000149011612` you get by
    /// widening to `Double`), matching Foundation. `.ecma262` / `.sqlitePrintfG` are binary64 profiles
    /// (JS / SQLite), so they widen to `Double` — documented, not the default path.
    @inlinable
    public static func appendFiniteFloat(
        _ v: Float, numberFormat: JSONEncodingOptions.NumberFormat, to bytes: inout [UInt8]
    ) {
        switch numberFormat {
            case .ecma262: appendECMANumber(Double(v), to: &bytes)
            case .swiftShortest: bytes.append(contentsOf: v.description.utf8)
            case .sqlitePrintfG: appendSQLitePrintfG(Double(v), to: &bytes)
        }
    }

    /// Emits a `Float` per the encoding `options`: `nonFinite` chooses throw / `null` / string-literal,
    /// and a finite value goes through ``appendFiniteFloat(_:numberFormat:to:)``. The single source of
    /// truth for every `Float` the encoders emit — so `Float` keeps its own shortest form rather than a
    /// widened `Double`'s.
    public static func appendFloat(_ v: Float, options: JSONEncodingOptions, to bytes: inout [UInt8]) throws {
        guard v.isFinite else {
            switch options.nonFinite {
                case .throw:
                    throw EncodingError.invalidValue(
                        v, .init(codingPath: [], debugDescription: "Non-finite \(v) cannot be encoded as JSON"))
                case .null:
                    appendNull(to: &bytes)
                case .stringLiterals(let pos, let neg, let nan):
                    appendString(
                        v.isNaN ? nan : (v > 0 ? pos : neg), to: &bytes,
                        escapeSlashes: options.escapeSlashes, escapeHTMLUnsafe: options.escapeHTMLUnsafe)
            }
            return
        }
        appendFiniteFloat(v, numberFormat: options.numberFormat, to: &bytes)
    }

    /// SQLite's `%!.15g` real rendering, byte-for-byte with `sqlite3` `json()`/`json_quote()`. The
    /// digits, rounding (15 significant figures), `%g` fixed-vs-exponential selection, and `e±NN`
    /// exponent come straight from C `vsnprintf("%.15g")`; SQLite's two deviations are applied on top —
    /// keep one fractional digit so a real stays a real (`5.0`, `1.0e+20`), and render `±0.0` as `0.0`.
    /// Caller guarantees `v` is finite (non-finite is handled before the format switch). Doubles only;
    /// integer values keep their exact decimal form on the `.int` path. Not `@inlinable`: it calls the
    /// libc `vsnprintf`, which is module-internal.
    public static func appendSQLitePrintfG(_ v: Double, to bytes: inout [UInt8]) {
        if v == 0 {  // normalizes -0.0 → 0.0
            bytes.append(0x30)
            bytes.append(0x2E)
            bytes.append(0x30)
            return
        }
        var buf = [CChar](repeating: 0, count: 32)
        _ = buf.withUnsafeMutableBufferPointer { p in
            withVaList([v]) { vsnprintf(p.baseAddress, 32, "%.15g", $0) }
        }
        var count = 0
        var dotIndex = -1
        var expIndex = -1
        while buf[count] != 0 {
            let c = buf[count]
            if c == 0x2E {
                dotIndex = count
            } else if (c == 0x65 || c == 0x45) && expIndex < 0 {  // 'e' / 'E'
                expIndex = count
            }
            count += 1
        }
        // Already has a fractional digit: copy verbatim.
        if dotIndex >= 0 {
            for i in 0 ..< count { bytes.append(UInt8(bitPattern: buf[i])) }
            return
        }
        // No '.': insert ".0" — before the exponent if present, else at the end.
        let cut = expIndex >= 0 ? expIndex : count
        for i in 0 ..< cut { bytes.append(UInt8(bitPattern: buf[i])) }
        bytes.append(0x2E)
        bytes.append(0x30)
        for i in cut ..< count { bytes.append(UInt8(bitPattern: buf[i])) }
    }
}
