// Canonical shortest-`Double` → JSON bytes. The significant digits come from Swift's own
// `Double.description` (the standard library's correctly-rounded shortest form — pure Swift, locale
// independent, no libc), parsed once by `JSONOutput.withShortestDigits`; this file only applies the
// *presentation* rule. Owning the placement (rather than emitting `description` verbatim) pins ADJSON's
// output across Swift toolchain versions and removes `description`'s value-dependent fixed/scientific
// quirk (e.g. `2^53` prints fixed but `2^53+2` flips to scientific).

@usableFromInline
enum JSONShortest {
    // Fixed-notation window on the scientific exponent `E` (value = d₀.d₁…d_{k-1} × 10^E). Matches
    // `Double.description` across the normal range (1e-4…1e15 print in fixed form); outside it, and only
    // outside it, we use scientific — deterministically, with no value-dependent exception.
    static let fixedLowExponent = -4
    static let fixedHighExponent = 15

    /// Append the shortest round-trippable decimal for a **finite** `v`, in the canonical form: a
    /// `Double` always keeps a fractional part (`2.0`) or an exponent, so it never reads as a bare
    /// integer. Not `@inlinable` (it reaches `Double.description`), but `@usableFromInline` so the
    /// inlinable ``JSONOutput/appendFiniteDouble`` can call it.
    @usableFromInline
    static func appendShortest(_ v: Double, to bytes: inout [UInt8]) {
        JSONOutput.withShortestDigits(v) { negative, digits, pointPos in
            if negative { bytes.append(0x2D) }
            let k = digits.count
            if k == 0 {  // zero (incl. -0.0)
                bytes.append(0x30)
                bytes.append(0x2E)
                bytes.append(0x30)  // "0.0"
                return
            }
            let n = pointPos  // significant digits to the left of the decimal point
            let exponent = n - 1  // the value's scientific exponent
            if exponent >= fixedLowExponent, exponent <= fixedHighExponent {
                if n <= 0 {
                    bytes.append(0x30)
                    bytes.append(0x2E)
                    for _ in 0..<(-n) { bytes.append(0x30) }
                    for x in 0..<k { bytes.append(digits[x]) }
                } else if n >= k {
                    for x in 0..<k { bytes.append(digits[x]) }
                    for _ in 0..<(n - k) { bytes.append(0x30) }
                    bytes.append(0x2E)
                    bytes.append(0x30)
                } else {
                    for x in 0..<n { bytes.append(digits[x]) }
                    bytes.append(0x2E)
                    for x in n..<k { bytes.append(digits[x]) }
                }
            } else {
                bytes.append(digits[0])
                if k > 1 {
                    bytes.append(0x2E)
                    for x in 1..<k { bytes.append(digits[x]) }
                }
                bytes.append(0x65)  // 'e'
                bytes.append(exponent >= 0 ? 0x2B : 0x2D)
                let absExp = abs(exponent)
                if absExp < 10 {
                    bytes.append(0x30)
                    bytes.append(0x30 + UInt8(absExp))
                } else {
                    JSONOutput.appendInteger(absExp, to: &bytes)
                }
            }
        }
    }
}
