import Foundation

// Single-pass recursive-descent scanner that builds the tape WITHOUT materializing
// any value. In strict mode it enforces the RFC 8259 grammar (number shape, escape
// validity, UTF-8 well-formedness); in lenient mode it scans permissively.
struct TapeBuilder {
    let p: UnsafePointer<UInt8>
    let n: Int
    let strict: Bool
    let checkDuplicates: Bool
    let maxDepth: Int
    var i = 0
    var slots: [UInt64]
    var depth = 0

    init(_ p: UnsafePointer<UInt8>, _ n: Int, options: JSONParseOptions) {
        self.p = p
        self.n = n
        self.strict = options.isStrict
        self.checkDuplicates = options.duplicateKeys == .throwError
        self.maxDepth = options.maxDepth
        self.slots = []
        slots.reserveCapacity(n / 4 + 8)
    }

    mutating func build() throws -> [UInt64] {
        skipWS()
        try parseValue()
        skipWS()
        if i != n { throw JSONError.trailingData(at: i) }
        return slots
    }

    @inline(__always) mutating func skipWS() {
        while i < n {
            let c = p[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 } else { break }
        }
    }

    mutating func parseValue() throws {
        skipWS()
        guard i < n else { throw JSONError.unexpectedEndOfInput }
        switch p[i] {
        case 0x7B: try parseObject()
        case 0x5B: try parseArray()
        case 0x22: try scanString()
        case 0x74, 0x66, 0x6E: try scanLiteral()
        case 0x2D, 0x30...0x39: try scanNumber()
        default: throw JSONError.unexpectedCharacter(p[i], at: i)
        }
    }

    mutating func parseObject() throws {
        depth += 1
        if depth > maxDepth { throw JSONError.depthExceeded(at: i) }
        let openIdx = slots.count
        slots.append(0)  // placeholder, patched at close
        i += 1  // {
        skipWS()
        var count = 0
        var keyRanges: [(offset: Int, length: Int)] = []
        if i < n && p[i] == 0x7D {
            i += 1
        } else {
            while true {
                skipWS()
                guard i < n, p[i] == 0x22 else {
                    throw JSONError.unexpectedCharacter(i < n ? p[i] : 0, at: i)
                }
                let keyStart = i
                try scanString()  // key
                if checkDuplicates { try recordKey(keyStart, into: &keyRanges) }
                skipWS()
                guard i < n, p[i] == 0x3A else {
                    throw JSONError.unexpectedCharacter(i < n ? p[i] : 0, at: i)
                }
                i += 1  // :
                try parseValue()
                count += 1
                skipWS()
                guard i < n else { throw JSONError.unexpectedEndOfInput }
                let c = p[i]
                if c == 0x2C {
                    i += 1
                    continue
                }
                if c == 0x7D {
                    i += 1
                    break
                }
                throw JSONError.unexpectedCharacter(c, at: i)
            }
        }
        slots[openIdx] = Slot.container(JSONKind.object.rawValue, count: count, next: slots.count)
        depth -= 1
    }

    // Compares the just-scanned key (raw bytes) against earlier keys in this object.
    mutating func recordKey(_ keyStart: Int, into keyRanges: inout [(offset: Int, length: Int)]) throws {
        let keySlot = slots[slots.count - 1]
        let offset = Slot.low(keySlot)
        let length = Slot.length(keySlot)
        for previous in keyRanges
        where previous.length == length && (length == 0 || memcmp(p + previous.offset, p + offset, length) == 0) {
            throw JSONError.duplicateKey(at: keyStart)
        }
        keyRanges.append((offset, length))
    }

    mutating func parseArray() throws {
        depth += 1
        if depth > maxDepth { throw JSONError.depthExceeded(at: i) }
        let openIdx = slots.count
        slots.append(0)
        i += 1  // [
        skipWS()
        var count = 0
        if i < n && p[i] == 0x5D {
            i += 1
        } else {
            while true {
                try parseValue()
                count += 1
                skipWS()
                guard i < n else { throw JSONError.unexpectedEndOfInput }
                let c = p[i]
                if c == 0x2C {
                    i += 1
                    continue
                }
                if c == 0x5D {
                    i += 1
                    break
                }
                throw JSONError.unexpectedCharacter(c, at: i)
            }
        }
        slots[openIdx] = Slot.container(JSONKind.array.rawValue, count: count, next: slots.count)
        depth -= 1
    }

    // Records the string's content range + hasEscape flag; validates escapes and
    // UTF-8 in strict mode. Does not decode.
    mutating func scanString() throws {
        let start = i + 1
        var j = start
        var esc: UInt64 = 0
        while j < n {
            let c = p[j]
            if c == 0x22 { break }
            if c == 0x5C {
                esc = 1
                if strict {
                    try validateEscape(&j)
                } else {
                    j += 2
                }
                continue
            }
            if c < 0x20 { throw JSONError.invalidString(at: j) }
            if strict && c >= 0x80 {
                j += try utf8SequenceLength(p, j, n)
                continue
            }
            j += 1
        }
        guard j < n else { throw JSONError.unexpectedEndOfInput }
        let length = j - start
        guard length <= Slot.maxLength else { throw JSONError.documentTooLarge }
        slots.append(Slot.scalar(JSONKind.string.rawValue, offset: start, length: length, flags: esc))
        i = j + 1
    }

    // `p[j]` is a backslash; validates the escape and advances `j` past it.
    mutating func validateEscape(_ j: inout Int) throws {
        guard j + 1 < n else { throw JSONError.invalidString(at: j) }
        switch p[j + 1] {
        case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
            j += 2
        case 0x75:  // \uXXXX
            let high = try hex4(j + 2)
            if high >= 0xD800 && high <= 0xDBFF {
                guard j + 7 < n, p[j + 6] == 0x5C, p[j + 7] == 0x75 else { throw JSONError.invalidString(at: j) }
                let low = try hex4(j + 8)
                guard low >= 0xDC00 && low <= 0xDFFF else { throw JSONError.invalidString(at: j) }
                j += 12
            } else if high >= 0xDC00 && high <= 0xDFFF {
                throw JSONError.invalidString(at: j)  // lone low surrogate
            } else {
                j += 6
            }
        default:
            throw JSONError.invalidString(at: j)  // invalid escape character
        }
    }

    func hex4(_ at: Int) throws -> UInt16 {
        guard at + 4 <= n else { throw JSONError.invalidString(at: at) }
        var value: UInt16 = 0
        for k in 0..<4 {
            guard let digit = hexValue(p[at + k]) else { throw JSONError.invalidString(at: at) }
            value = (value << 4) | UInt16(digit)
        }
        return value
    }

    @inline(__always) func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x61...0x66: return b - 0x61 + 10
        case 0x41...0x46: return b - 0x41 + 10
        default: return nil
        }
    }

    mutating func scanNumber() throws {
        let start = i
        var isInt: UInt64 = 1
        if strict {
            try scanNumberStrict(&isInt, start: start)
        } else {
            if p[i] == 0x2D { i += 1 }
            while i < n {
                let c = p[i]
                if c >= 0x30 && c <= 0x39 {
                    i += 1
                } else if c == 0x2E || c == 0x65 || c == 0x45 || c == 0x2B || c == 0x2D {
                    isInt = 0
                    i += 1
                } else {
                    break
                }
            }
        }
        let length = i - start
        guard length > 0, length <= Slot.maxLength else { throw JSONError.invalidNumber(at: start) }
        slots.append(Slot.scalar(JSONKind.number.rawValue, offset: start, length: length, flags: isInt))
    }

    // RFC 8259: [ '-' ] ( '0' | [1-9][0-9]* ) [ '.' [0-9]+ ] [ (e|E) [+|-] [0-9]+ ]
    mutating func scanNumberStrict(_ isInt: inout UInt64, start: Int) throws {
        if i < n && p[i] == 0x2D { i += 1 }
        guard i < n else { throw JSONError.invalidNumber(at: start) }
        if p[i] == 0x30 {
            i += 1
            if i < n && isDigit(p[i]) { throw JSONError.invalidNumber(at: start) }  // no leading zero
        } else if p[i] >= 0x31 && p[i] <= 0x39 {
            i += 1
            while i < n && isDigit(p[i]) { i += 1 }
        } else {
            throw JSONError.invalidNumber(at: start)
        }
        if i < n && p[i] == 0x2E {
            isInt = 0
            i += 1
            guard i < n && isDigit(p[i]) else { throw JSONError.invalidNumber(at: start) }
            while i < n && isDigit(p[i]) { i += 1 }
        }
        if i < n && (p[i] == 0x65 || p[i] == 0x45) {
            isInt = 0
            i += 1
            if i < n && (p[i] == 0x2B || p[i] == 0x2D) { i += 1 }
            guard i < n && isDigit(p[i]) else { throw JSONError.invalidNumber(at: start) }
            while i < n && isDigit(p[i]) { i += 1 }
        }
    }

    @inline(__always) func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    mutating func scanLiteral() throws {
        let start = i
        switch p[i] {
        case 0x74:
            try expectLiteral("true")
            slots.append(Slot.scalar(JSONKind.boolTrue.rawValue, offset: start, length: 4, flags: 0))
        case 0x66:
            try expectLiteral("false")
            slots.append(Slot.scalar(JSONKind.boolFalse.rawValue, offset: start, length: 5, flags: 0))
        default:
            try expectLiteral("null")
            slots.append(Slot.scalar(JSONKind.null.rawValue, offset: start, length: 4, flags: 0))
        }
    }

    @inline(__always) mutating func expectLiteral(_ lit: StaticString) throws {
        let len = lit.utf8CodeUnitCount
        guard i + len <= n, memcmp(p + i, lit.utf8Start, len) == 0 else {
            throw JSONError.unexpectedCharacter(i < n ? p[i] : 0, at: i)
        }
        i += len
    }
}
