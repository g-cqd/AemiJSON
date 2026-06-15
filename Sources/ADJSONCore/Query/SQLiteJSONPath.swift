/// Errors from parsing a SQLite-dialect JSON path. A *missing* path (one that is
/// syntactically valid but resolves to nothing) is not an error — `evaluate` returns a
/// missing `JSON` sentinel for that, mirroring `json_extract`'s NULL result.
public enum SQLiteJSONPathError: Error, Sendable, Equatable {
    case invalidSyntax(at: Int)
}

/// A SQLite-dialect JSON path (the grammar used by `json_extract`, `->`, `->>`,
/// `json_set`, etc.), compiled once to a segment list and reusable. This is deliberately
/// distinct from RFC 9535 `JSONPath`: SQLite paths are *singular* (address at most one
/// node) and use a different, smaller grammar.
///
/// Grammar: a leading `$`, then zero or more of
/// - `.label` or `."quoted label"` — an object member (quoted labels use JSON string
///   escapes, so `$."a.b"` is a single key containing a dot),
/// - `[N]` — a non-negative array index,
/// - `[#-N]` — an array index counted from the end (`[#-1]` is the last element),
/// - `[#]` — the append position (one past the last element; never present on read).
public struct SQLiteJSONPath: Sendable, Equatable {
    public enum Segment: Sendable, Equatable {
        case key(String)
        case index(Int)
        /// `[#-N]`: the element at `count - N` (so `fromEnd(1)` is the last element).
        case fromEnd(Int)
        /// `[#]`: the position one past the last element (used by `json_insert`/`json_set`).
        case append
    }

    public let segments: [Segment]

    public init(segments: [Segment]) { self.segments = segments }

    public init(_ string: String) throws(SQLiteJSONPathError) {
        var parser = Parser(bytes: Array(string.utf8))
        segments = try parser.parse()
    }

    /// Resolve the path against `root`, returning the addressed node or a missing `JSON`
    /// sentinel (`exists == false`) when any segment doesn't resolve. Never traps.
    public func evaluate(_ root: JSON) -> JSON {
        var current = root
        for segment in segments {
            switch segment {
            case .key(let key):
                current = current.isObject ? current[key] : .missing(current.doc)
            case .index(let i):
                current = current.isArray ? current[index: i] : .missing(current.doc)
            case .fromEnd(let n):
                if current.isArray, case let i = current.count - n, i >= 0 {
                    current = current[index: i]
                } else {
                    current = .missing(current.doc)
                }
            case .append:
                current = .missing(current.doc)
            }
            if !current.exists { return current }
        }
        return current
    }
}

extension SQLiteJSONPath {
    struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func parse() throws(SQLiteJSONPathError) -> [Segment] {
            guard i < bytes.count, bytes[i] == 0x24 else { throw .invalidSyntax(at: i) }  // $
            i += 1
            var segments: [Segment] = []
            while i < bytes.count {
                switch bytes[i] {
                case 0x2E:  // .
                    i += 1
                    segments.append(.key(try key()))
                case 0x5B:  // [
                    i += 1
                    segments.append(try subscriptSegment())
                default:
                    throw .invalidSyntax(at: i)
                }
            }
            return segments
        }

        mutating func key() throws(SQLiteJSONPathError) -> String {
            guard i < bytes.count else { throw .invalidSyntax(at: i) }
            if bytes[i] == 0x22 { return try quotedKey() }
            let start = i
            while i < bytes.count, bytes[i] != 0x2E, bytes[i] != 0x5B { i += 1 }
            guard i > start else { throw .invalidSyntax(at: start) }  // empty label
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        mutating func quotedKey() throws(SQLiteJSONPathError) -> String {
            i += 1  // opening quote
            var out: [UInt8] = []
            while i < bytes.count {
                let b = bytes[i]
                if b == 0x22 {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if b == 0x5C {  // backslash
                    i += 1
                    guard i < bytes.count else { throw .invalidSyntax(at: i) }
                    switch bytes[i] {
                    case 0x22: out.append(0x22)
                    case 0x5C: out.append(0x5C)
                    case 0x2F: out.append(0x2F)
                    case 0x62: out.append(0x08)
                    case 0x66: out.append(0x0C)
                    case 0x6E: out.append(0x0A)
                    case 0x72: out.append(0x0D)
                    case 0x74: out.append(0x09)
                    case 0x75:  // \uXXXX (+ surrogate pairs)
                        guard let scalar = unicodeEscape() else { throw .invalidSyntax(at: i) }
                        out.append(contentsOf: Array(String(scalar).utf8))
                        continue
                    default: throw .invalidSyntax(at: i)
                    }
                    i += 1
                    continue
                }
                out.append(b)
                i += 1
            }
            throw .invalidSyntax(at: i)  // unterminated
        }

        mutating func unicodeEscape() -> Unicode.Scalar? {
            func hex4() -> UInt32? {
                guard i + 5 <= bytes.count else { return nil }
                var v: UInt32 = 0
                for k in 1...4 {
                    let b = bytes[i + k]
                    let digit: UInt32
                    switch b {
                    case 0x30...0x39: digit = UInt32(b - 0x30)
                    case 0x41...0x46: digit = UInt32(b - 0x41 + 10)
                    case 0x61...0x66: digit = UInt32(b - 0x61 + 10)
                    default: return nil
                    }
                    v = v << 4 | digit
                }
                return v
            }
            guard let first = hex4() else { return nil }
            i += 5
            if first >= 0xD800, first <= 0xDBFF,
                i + 1 < bytes.count, bytes[i] == 0x5C, bytes[i + 1] == 0x75
            {
                i += 1  // backslash; hex4 expects i at 'u'
                if let second = hex4(), second >= 0xDC00, second <= 0xDFFF {
                    i += 5
                    let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    return Unicode.Scalar(combined)
                }
                i -= 1
            }
            return Unicode.Scalar(first) ?? Unicode.Scalar(0xFFFD)
        }

        mutating func subscriptSegment() throws(SQLiteJSONPathError) -> Segment {
            guard i < bytes.count else { throw .invalidSyntax(at: i) }
            if bytes[i] == 0x23 {  // #
                i += 1
                if i < bytes.count, bytes[i] == 0x2D {  // -
                    i += 1
                    let n = try integer()
                    try expect(0x5D)
                    return .fromEnd(n)
                }
                try expect(0x5D)
                return .append
            }
            let n = try integer()
            try expect(0x5D)
            return .index(n)
        }

        mutating func integer() throws(SQLiteJSONPathError) -> Int {
            let start = i
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
            guard i > start, let value = Int(String(decoding: bytes[start..<i], as: UTF8.self)) else {
                throw .invalidSyntax(at: start)
            }
            return value
        }

        mutating func expect(_ byte: UInt8) throws(SQLiteJSONPathError) {
            guard i < bytes.count, bytes[i] == byte else { throw .invalidSyntax(at: i) }
            i += 1
        }
    }
}
