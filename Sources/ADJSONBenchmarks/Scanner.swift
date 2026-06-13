import Foundation

// Raw structural scan: single pass that records the offset of every structural
// token / string / scalar start into a reusable tape, WITHOUT materializing any
// value. This is the ceiling for a lazy, tape-backed untyped representation
// (the real way to beat JSONSerialization). No per-node String/Dictionary.

func scanScalar(_ p: UnsafePointer<UInt8>, _ n: Int, _ tape: inout [Int32]) {
    tape.removeAll(keepingCapacity: true)
    var i = 0
    while i < n {
        let c = p[i]
        switch c {
        case 0x22:  // string: record start, skip interior (honor escapes)
            tape.append(Int32(i))
            i += 1
            while i < n {
                let d = p[i]
                if d == 0x5C {
                    i += 2
                    continue
                }
                if d == 0x22 { break }
                i += 1
            }
            i += 1
        case 0x7B, 0x7D, 0x5B, 0x5D, 0x3A, 0x2C:
            tape.append(Int32(i))
            i += 1
        case 0x20, 0x0A, 0x0D, 0x09:
            i += 1
        default:  // scalar (number / true / false / null)
            tape.append(Int32(i))
            i += 1
            while i < n {
                let d = p[i]
                if d == 0x2C || d == 0x7D || d == 0x5D || d == 0x3A
                    || d == 0x20 || d == 0x0A || d == 0x0D || d == 0x09
                {
                    break
                }
                i += 1
            }
        }
    }
}

// Same work, but skip long non-structural runs 16 bytes at a time using SIMD.
func scanSIMD(_ p: UnsafePointer<UInt8>, _ n: Int, _ tape: inout [Int32]) {
    tape.removeAll(keepingCapacity: true)
    let q = SIMD16<UInt8>(repeating: 0x22)
    let bs = SIMD16<UInt8>(repeating: 0x5C)
    let comma = SIMD16<UInt8>(repeating: 0x2C)
    let rb = SIMD16<UInt8>(repeating: 0x7D)
    let rbk = SIMD16<UInt8>(repeating: 0x5D)
    let colon = SIMD16<UInt8>(repeating: 0x3A)
    let sp = SIMD16<UInt8>(repeating: 0x21)
    var i = 0
    while i < n {
        let c = p[i]
        switch c {
        case 0x22:
            tape.append(Int32(i))
            i += 1
            while i + 16 <= n {
                let v = UnsafeRawPointer(p + i).loadUnaligned(as: SIMD16<UInt8>.self)
                if any((v .== q) .| (v .== bs)) { break }
                i += 16
            }
            while i < n {
                let d = p[i]
                if d == 0x5C {
                    i += 2
                    continue
                }
                if d == 0x22 { break }
                i += 1
            }
            i += 1
        case 0x7B, 0x7D, 0x5B, 0x5D, 0x3A, 0x2C:
            tape.append(Int32(i))
            i += 1
        case 0x20, 0x0A, 0x0D, 0x09:
            i += 1
        default:
            tape.append(Int32(i))
            i += 1
            while i + 16 <= n {
                let v = UnsafeRawPointer(p + i).loadUnaligned(as: SIMD16<UInt8>.self)
                if any((v .< sp) .| (v .== comma) .| (v .== rb) .| (v .== rbk) .| (v .== colon)) { break }
                i += 16
            }
            while i < n {
                let d = p[i]
                if d == 0x2C || d == 0x7D || d == 0x5D || d == 0x3A
                    || d == 0x20 || d == 0x0A || d == 0x0D || d == 0x09
                {
                    break
                }
                i += 1
            }
        }
    }
}
