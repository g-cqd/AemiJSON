// The insignificant characters JSON5 adds to ASCII white space, matched on UTF-8 without decoding.
//
// json5.org §8 counts U+00A0, U+FEFF and every Unicode space separator (Zs) as white space, and §6 makes
// U+2028 / U+2029 line terminators, which are insignificant between tokens and end a `//` comment. The set
// is closed and tiny, so a lead-byte switch beats any table: only a lead byte of `C2 E1 E2 E3 EF` can start
// a member, and every member is two or three bytes.
//
//     U+00A0 C2 A0          U+2000...U+200A E2 80 80...8A     U+205F E2 81 9F
//     U+1680 E1 9A 80       U+2028, U+2029 E2 80 A8, A9       U+3000 E3 80 80
//     U+202F E2 80 AF       U+FEFF EF BB BF
//
// Shared by the tape scanner and the SAX tokenizer so the two grammars cannot drift apart. The matcher is
// resumable like the rest of `Tokenizer.swift`: a sequence cut short by the end of the buffer reports
// ``Match/needMore``, which a streaming reader treats as unfinished and a whole-buffer reader treats as
// ordinary (and then invalid) input.
enum JSON5Whitespace {
    /// What the bytes at one position hold.
    enum Match: Equatable {
        /// Not white space (or a malformed sequence): the byte is significant input.
        case none
        /// A white-space character of this many bytes (2 or 3).
        case space(Int)
        /// The buffer ends inside a sequence that could still become white space.
        case needMore
    }

    /// Classifies `p[i]` (any byte; non-members are `.none` after one comparison).
    ///
    /// - Parameters:
    ///   - p: The buffer; `p[i ..< count]` is readable.
    ///   - i: Index of the first byte of the candidate, `i < count`.
    ///   - count: The end of the valid bytes in `p` (exclusive).
    /// - Returns: The white-space character at `i`, `.needMore` when the buffer ends inside a possible one,
    ///   or `.none`.
    static func match(_ p: UnsafePointer<UInt8>, _ i: Int, _ count: Int) -> Match {
        // Caller owns `p[0 ..< count]` and guarantees `i < count`; every read below is guarded by `available`.
        let available = count - i
        switch unsafe p[i] {
            case 0xC2:  // U+00A0
                guard available >= 2 else { return .needMore }
                return unsafe p[i + 1] == 0xA0 ? .space(2) : .none
            case 0xE1:  // U+1680
                return unsafe threeByte(p, i, available, second: 0x9A, third: 0x80)
            case 0xE2:  // U+2000...U+200A, U+2028, U+2029, U+202F, U+205F
                guard available >= 2 else { return .needMore }
                let second = unsafe p[i + 1]
                guard second == 0x80 || second == 0x81 else { return .none }
                guard available >= 3 else { return .needMore }
                return unsafe isSpaceTail(second, p[i + 2]) ? .space(3) : .none
            case 0xE3:  // U+3000
                return unsafe threeByte(p, i, available, second: 0x80, third: 0x80)
            case 0xEF:  // U+FEFF
                return unsafe threeByte(p, i, available, second: 0xBB, third: 0xBF)
            default:
                return .none
        }
    }

    /// A three-byte space whose second and third bytes are fixed (`E1 9A 80`, `E3 80 80`, `EF BB BF`), cut
    /// short or not: `.needMore` while the bytes present are still a prefix of it.
    private static func threeByte(
        _ p: UnsafePointer<UInt8>, _ i: Int, _ available: Int, second: UInt8, third: UInt8
    ) -> Match {
        guard unsafe available < 2 || p[i + 1] == second else { return .none }
        guard available >= 3 else { return .needMore }
        return unsafe p[i + 2] == third ? .space(3) : .none
    }

    /// The last byte of an `E2 80 xx` / `E2 81 xx` space, given its second byte.
    private static func isSpaceTail(_ second: UInt8, _ third: UInt8) -> Bool {
        if second == 0x81 { return third == 0x9F }  // U+205F
        return (third >= 0x80 && third <= 0x8A) || third == 0xA8 || third == 0xA9 || third == 0xAF
    }

    /// Whether `p[i ..< count]` begins with U+2028 or U+2029, the line terminators beyond ASCII.
    static func isLineSeparator(_ p: UnsafePointer<UInt8>, _ i: Int, _ count: Int) -> Bool {
        // The three bytes are read only after `i + 2 < count` holds.
        guard i + 2 < count, unsafe p[i] == 0xE2, unsafe p[i + 1] == 0x80 else { return false }
        return unsafe p[i + 2] == 0xA8 || p[i + 2] == 0xA9
    }

    /// The index where the `//` comment whose text begins at `from` ends: the first LF, CR, U+2028 or
    /// U+2029, or `count` when the buffer ends first.
    static func lineCommentEnd(_ p: UnsafePointer<UInt8>, from: Int, count: Int) -> Int {
        var k = from
        while k < count {
            let byte = unsafe p[k]
            if byte == 0x0A || byte == 0x0D { break }
            if byte == 0xE2, unsafe isLineSeparator(p, k, count) { break }
            k += 1
        }
        return k
    }
}
