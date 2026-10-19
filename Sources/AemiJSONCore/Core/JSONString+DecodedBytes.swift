import AemiKernel
import AemiKernels

extension JSONString {
    /// Replaces `output` with the decoded bytes of an object-key body, without making a `String`.
    ///
    /// The result is byte-for-byte what ``unescape(_:_:_:)`` (or ``unescapeJSON5(_:_:_:)`` when `json5`)
    /// writes into a `String`, minus the repair of ill-formed UTF-8 a `String` performs. That is the
    /// equality ``unescapedEquals(_:_:_:_:_:)`` and ``unescapedEqualsJSON5(_:_:_:_:_:)`` apply when a
    /// lookup matches a key, so two keys are one key for duplicate detection exactly when a lookup cannot
    /// tell them apart. `StringUnescapeTests` and `DuplicateKeyEscapeTests` pin the three against each
    /// other.
    ///
    /// `output` keeps its capacity between calls, so a scan that decodes many keys reuses one buffer; its
    /// capacity never exceeds the longest escaped key, which is bounded by the input.
    ///
    /// - Parameters:
    ///   - p: Backing UTF-8 buffer.
    ///   - offset: Start of the key body in `p`.
    ///   - length: Byte length of the key body.
    ///   - json5: Whether the body uses JSON5 escapes (`\x`, `\v`, `\0`, line continuations).
    ///   - output: The buffer to refill; its previous contents are discarded.
    /// - Precondition: The scanner validated `p[offset ..< offset + length]` and its escapes.
    /// - Complexity: O(length) time; O(length) space the first time, none once `output` has grown.
    static func appendUnescaped(
        _ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int, json5: Bool,
        replacing output: inout ContiguousArray<UInt8>
    ) {
        // Caller owns `p[offset ..< offset + length]` for this call; reads stay in that range and `p`
        // never escapes. Offsets and lengths come from the tape and are non-negative.
        assert(offset >= 0 && length >= 0, "appendUnescaped requires a non-negative byte range")
        output.removeAll(keepingCapacity: true)
        output.reserveCapacity(length)  // no escape decodes to more bytes than it occupies
        var j = offset
        let end = offset + length
        while j < end {
            // Copy the run of plain bytes up to the next backslash in one step.
            let run = unsafe AemiKernels.firstIndexOfByte(base: p + j, count: end - j, needle: 0x5C)
            if run > 0 {
                unsafe output.append(contentsOf: UnsafeBufferPointer(start: p + j, count: run))
                j += run
            }
            guard j + 1 < end else { break }
            let escape = unsafe p[j + 1]
            j += 2
            switch escape {
                case 0x22, 0x5C, 0x2F: output.append(escape)
                case 0x6E: output.append(0x0A)
                case 0x74: output.append(0x09)
                case 0x72: output.append(0x0D)
                case 0x62: output.append(0x08)
                case 0x66: output.append(0x0C)
                case 0x75:
                    let scalar = unsafe decodeUnicodeEscapeScalar(p, &j, end)
                    appendUTF8(scalar, to: &output)
                default:
                    if json5 {
                        unsafe appendJSON5Escape(escape, p, &j, end, to: &output)
                    } else {
                        output.append(escape)  // lenient identity escape
                    }
            }
        }
    }

    /// The JSON5 escapes beyond the JSON set; `escape` is the byte after the backslash and `j` is past it.
    private static func appendJSON5Escape(
        _ escape: UInt8, _ p: UnsafePointer<UInt8>, _ j: inout Int, _ end: Int,
        to output: inout ContiguousArray<UInt8>
    ) {
        switch escape {
            case 0x76: output.append(0x0B)  // \v
            case 0x30: output.append(0x00)  // \0
            case 0x78:  // \xHH: U+0000...U+00FF
                guard j + 1 < end else { return }
                let value = unsafe UInt32(Hex.value(p[j]) ?? 0) << 4 | UInt32(Hex.value(p[j + 1]) ?? 0)
                j += 2
                appendUTF8(value, to: &output)
            case 0x0A: break  // \ + LF: line continuation, elided
            case 0x0D:  // \ + CR or CRLF: line continuation, elided
                if j < end, unsafe p[j] == 0x0A { j += 1 }
            default:
                if escape >= 0x80 {
                    unsafe appendMultiByteIdentityEscape(escape, p, &j, end, to: &output)
                } else {
                    output.append(escape)  // identity escape \X -> X
                }
        }
    }

    /// An identity-escaped multi-byte scalar, or a U+2028 / U+2029 line continuation (which is elided).
    /// `j` is just past the lead byte.
    private static func appendMultiByteIdentityEscape(
        _ lead: UInt8, _ p: UnsafePointer<UInt8>, _ j: inout Int, _ end: Int,
        to output: inout ContiguousArray<UInt8>
    ) {
        if unsafe JSON5Whitespace.isLineSeparator(p, j - 1, end) {
            j += 2
            return
        }
        output.append(lead)
        for _ in 1 ..< (JSONUTF8.leadLength(lead) ?? 1) where j < end {
            output.append(unsafe p[j])
            j += 1
        }
    }

    /// Appends `scalar` as UTF-8: a decoded escape is always a valid scalar (`decodeUnicodeEscapeScalar` maps
    /// an unpaired surrogate to U+FFFD, and `\x` stops at U+00FF).
    private static func appendUTF8(_ scalar: UInt32, to output: inout ContiguousArray<UInt8>) {
        guard let valid = Unicode.Scalar(scalar) else {
            output.append(0xEF)  // U+FFFD, never reached for a decoded escape
            output.append(0xBF)
            output.append(0xBD)
            return
        }
        Unicode.UTF8.encode(valid) { output.append($0) }
    }
}
