import AemiKernel

extension JSONString {
    /// Compares a JSON5 string body with UTF-8 bytes without materializing a string.
    /// - Precondition: The parser validated the source range and its escapes; the target range is valid.
    /// - Complexity: O(length) time and O(1) extra space.
    public static func unescapedEqualsJSON5(
        _ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int, _ target: UnsafePointer<UInt8>, _ targetLength: Int
    ) -> Bool {
        assert(offset >= 0 && length >= 0 && targetLength >= 0, "JSON5 comparison requires non-negative ranges")
        let targetBytes = unsafe UnsafeBufferPointer(start: target, count: targetLength)
        var targetIndex = 0
        var sourceIndex = offset
        let end = offset + length
        while sourceIndex < end {
            let byte = unsafe p[sourceIndex]
            sourceIndex += 1
            if byte != 0x5C {
                if unsafe !matchByte(byte, targetBytes, &targetIndex) { return false }
                continue
            }
            guard sourceIndex < end else { return false }
            let escape = unsafe p[sourceIndex]
            sourceIndex += 1
            if let decoded = simpleJSON5Escape(escape) {
                if unsafe !matchByte(decoded, targetBytes, &targetIndex) { return false }
                continue
            }
            switch escape {
                case 0x78:
                    if unsafe !matchHex(p, &sourceIndex, end, targetBytes, &targetIndex) { return false }
                case 0x75:
                    let scalar = unsafe decodeUnicodeEscapeScalar(p, &sourceIndex, end)
                    if unsafe !matchScalar(scalar, targetBytes, &targetIndex) { return false }
                case 0x0A: break
                case 0x0D:
                    if sourceIndex < end, unsafe p[sourceIndex] == 0x0A { sourceIndex += 1 }
                default:
                    if unsafe !matchIdentity(escape, p, &sourceIndex, end, targetBytes, &targetIndex) {
                        return false
                    }
            }
        }
        return targetIndex == targetBytes.count
    }

    @inline(__always)
    private static func matchByte(_ byte: UInt8, _ target: UnsafeBufferPointer<UInt8>, _ index: inout Int) -> Bool {
        if unsafe index >= target.count || target[index] != byte { return false }
        index += 1
        return true
    }

    @inline(__always)
    private static func simpleJSON5Escape(_ byte: UInt8) -> UInt8? {
        switch byte {
            case 0x22, 0x27, 0x5C, 0x2F: byte
            case 0x6E: 0x0A
            case 0x74: 0x09
            case 0x72: 0x0D
            case 0x62: 0x08
            case 0x66: 0x0C
            case 0x76: 0x0B
            case 0x30: 0
            default: nil
        }
    }

    @inline(__always)
    private static func matchHex(
        _ p: UnsafePointer<UInt8>, _ index: inout Int, _ end: Int,
        _ target: UnsafeBufferPointer<UInt8>, _ targetIndex: inout Int
    ) -> Bool {
        guard index + 1 < end else { return false }
        guard let hi = unsafe Hex.value(p[index]), let lo = unsafe Hex.value(p[index + 1]) else { return false }
        index += 2
        return unsafe matchScalar(UInt32(hi) << 4 | UInt32(lo), target, &targetIndex)
    }

    @inline(__always)
    private static func matchScalar(_ scalar: UInt32, _ target: UnsafeBufferPointer<UInt8>, _ index: inout Int) -> Bool
    {
        if scalar < 0x80 {
            return unsafe matchByte(UInt8(truncatingIfNeeded: scalar), target, &index)
        }
        if scalar < 0x800 {
            return unsafe matchByte(UInt8(truncatingIfNeeded: 0xC0 | (scalar >> 6)), target, &index)
                && matchByte(UInt8(truncatingIfNeeded: 0x80 | (scalar & 0x3F)), target, &index)
        }
        if scalar < 0x10000 {
            return unsafe matchByte(UInt8(truncatingIfNeeded: 0xE0 | (scalar >> 12)), target, &index)
                && matchByte(UInt8(truncatingIfNeeded: 0x80 | ((scalar >> 6) & 0x3F)), target, &index)
                && matchByte(UInt8(truncatingIfNeeded: 0x80 | (scalar & 0x3F)), target, &index)
        }
        return unsafe matchByte(UInt8(truncatingIfNeeded: 0xF0 | (scalar >> 18)), target, &index)
            && matchByte(UInt8(truncatingIfNeeded: 0x80 | ((scalar >> 12) & 0x3F)), target, &index)
            && matchByte(UInt8(truncatingIfNeeded: 0x80 | ((scalar >> 6) & 0x3F)), target, &index)
            && matchByte(UInt8(truncatingIfNeeded: 0x80 | (scalar & 0x3F)), target, &index)
    }

    @inline(__always)
    private static func matchIdentity(
        _ byte: UInt8, _ p: UnsafePointer<UInt8>, _ index: inout Int, _ end: Int,
        _ target: UnsafeBufferPointer<UInt8>, _ targetIndex: inout Int
    ) -> Bool {
        if byte < 0x80 { return unsafe matchByte(byte, target, &targetIndex) }
        let count = byte >= 0xF0 ? 4 : (byte >= 0xE0 ? 3 : 2)
        guard end - index >= count - 1 else { return false }
        if count == 3, byte == 0xE2, unsafe p[index] == 0x80,
            unsafe p[index + 1] == 0xA8 || p[index + 1] == 0xA9
        {
            index += 2
            return true
        }
        if unsafe !matchByte(byte, target, &targetIndex) { return false }
        for _ in 1 ..< count {
            if unsafe !matchByte(p[index], target, &targetIndex) { return false }
            index += 1
        }
        return true
    }
}
