import AemiTestKit
import Testing

@testable import AemiJSONCore

// The string scanners fast-forward eight bytes at a time with SWAR stop-masks and read only the first
// flagged lane. That is all the masks promise: zero when no byte of the word stops the scan, else the
// lowest flagged bit is the `0x80` bit of the first byte that does. Lanes above it can be flagged by a
// borrow, so a mask is never counted or walked. Each check compares a mask with a lane-by-lane
// reference, over words built from the bytes where the borrows happen.
struct StopMaskTests {
    /// The little-endian index of the first byte of `word` satisfying `stops`, or nil.
    private static func firstStop(_ word: UInt64, _ stops: (UInt8) -> Bool) -> Int? {
        for lane in 0 ..< 8 where stops(UInt8(truncatingIfNeeded: word >> (8 * lane))) { return lane }
        return nil
    }

    /// Whether `mask` reports exactly the first stop: nothing when there is none, else its `0x80` bit.
    private static func reportsFirstStop(_ mask: UInt64, _ first: Int?) -> Bool {
        guard let first else { return mask == 0 }
        return mask.trailingZeroBitCount == 8 * first + 7
    }

    /// A word of bytes drawn from both sides of every stop boundary, plus plain content.
    private static func word(_ rng: inout SeededRNG) -> UInt64 {
        let choices: [UInt8] = [
            0x00, 0x01, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x2E, 0x2F, 0x30, 0x5B, 0x5C, 0x5D, 0x61, 0x7F, 0x80, 0xFF
        ]
        var word: UInt64 = 0
        for lane in 0 ..< 8 { word |= UInt64(choices[rng.int(choices.count)]) << (8 * lane) }
        return word
    }

    @Test func parseStopMaskReportsTheFirstStopByte() {
        var rng = SeededRNG(seed: 0x5EA2_5705_0000_0001)
        var mismatches = 0
        for _ in 0 ..< 50_000 {
            let word = Self.word(&rng)
            let first = Self.firstStop(word) { $0 < 0x20 || $0 >= 0x80 || $0 == 0x22 || $0 == 0x5C }
            if !Self.reportsFirstStop(TapeBuilder.stringStopMask(word), first) { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }

    @Test(arguments: [false, true])
    func encodeStopMaskReportsTheFirstByteToEscape(escapeSlashes: Bool) {
        var rng = SeededRNG(seed: escapeSlashes ? 0x5EA2_E5C0_0000_0003 : 0x5EA2_E5C0_0000_0002)
        var mismatches = 0
        for _ in 0 ..< 50_000 {
            let word = Self.word(&rng)
            let first = Self.firstStop(word) { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C || (escapeSlashes && $0 == 0x2F) }
            if !Self.reportsFirstStop(JSONOutput.encodeStopMask(word, escapeSlashes: escapeSlashes), first) {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    // The contract really is first-lane only: a control char followed by a space flags the space too.
    @Test func aBorrowCanFlagPlainContentAboveTheFirstStop() {
        let controlThenSpaces: UInt64 = 0x2020_2020_2020_2010  // lane 0 is 0x10, the rest spaces
        let mask = TapeBuilder.stringStopMask(controlThenSpaces)
        #expect(mask.trailingZeroBitCount == 7)
        #expect(mask & 0x8000 != 0)  // lane 1, a plain space, is flagged by the borrow
    }
}
