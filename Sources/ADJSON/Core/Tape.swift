// The tape is a flat [UInt64] preorder flattening of the document. One slot per
// scalar/key/container — no per-node heap allocation. Containers store their
// element count + the tape index *after* their whole subtree, giving O(1) skip.
//
// Slot layout (64 bits):
//   bits 60..63  tag (JSONKind)
//   bits 32..59  aux  (28 bits)
//   bits  0..31  low  (32 bits)
//
// Scalars (string/number/literal):  aux = (length << 2) | flags,  low = byte offset
//   string flags bit0 = hasEscape
//   number flags bit0 = isInteger
// Containers (object/array):         aux = element count,          low = next index
//
// A single container holds at most 2^28-1 (`Slot.auxMask`) elements and the whole input is capped
// at 4 GiB; a document exceeding either is rejected as `JSONError.documentTooLarge`
// (see `TapeBuilder.closeContainer`).

@usableFromInline
enum JSONKind: UInt8 {
    case null = 0
    case boolFalse = 1
    case boolTrue = 2
    case number = 3
    case string = 4
    case object = 5
    case array = 6
}

@usableFromInline
enum Slot {
    @usableFromInline static let auxMask: UInt64 = 0x0FFF_FFFF
    @usableFromInline static let maxLength = 0x3FF_FFFF  // 2^26 - 1, fits length << 2 in 28 bits

    @inline(__always)
    @usableFromInline
    static func scalar(_ tag: UInt8, offset: Int, length: Int, flags: UInt64) -> UInt64 {
        (UInt64(tag) << 60)
            | ((((UInt64(length) << 2) | flags) & auxMask) << 32)
            | UInt64(UInt32(truncatingIfNeeded: offset))
    }

    @inline(__always)
    @usableFromInline
    static func container(_ tag: UInt8, count: Int, next: Int) -> UInt64 {
        (UInt64(tag) << 60)
            | ((UInt64(count) & auxMask) << 32)
            | UInt64(UInt32(truncatingIfNeeded: next))
    }

    @inline(__always) @usableFromInline static func tag(_ s: UInt64) -> UInt8 { UInt8(s >> 60) }
    @inline(__always) @usableFromInline static func low(_ s: UInt64) -> Int { Int(s & 0xFFFF_FFFF) }
    @inline(__always) @usableFromInline static func aux(_ s: UInt64) -> Int { Int((s >> 32) & auxMask) }
    @inline(__always) @usableFromInline static func length(_ s: UInt64) -> Int { aux(s) >> 2 }
    @inline(__always) @usableFromInline static func flags(_ s: UInt64) -> Int { aux(s) & 0x3 }
    @inline(__always) @usableFromInline static func count(_ s: UInt64) -> Int { aux(s) }
}
