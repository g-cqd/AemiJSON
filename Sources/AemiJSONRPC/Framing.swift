internal import AemiKernels

/// How messages are delimited on a byte stream.
public enum JSONRPCFraming: Sendable {
    /// The Language Server Protocol's base protocol: a `Content-Length` header block, then the body (``ContentLengthFraming``).
    case contentLength
    /// One message per line, as MCP's stdio transport sends them (``LineFraming``).
    case lines

    /// `body` framed for the stream.
    public func frame(_ body: [UInt8]) -> [UInt8] {
        switch self {
            case .contentLength: ContentLengthFraming.frame(body)
            case .lines: LineFraming.frame(body)
        }
    }
}

/// Why a stream is not a sequence of `Content-Length` frames. The stream cannot be resynchronized after one.
public enum JSONRPCFramingError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A header block is longer than the limit, ended or not.
    case headerTooLong
    /// A header block has no `Content-Length`, or its value is not a non-negative decimal integer.
    case missingContentLength
    /// A header announces a body longer than the limit.
    case contentTooLong(Int)

    public var description: String {
        switch self {
            case .headerTooLong: "a message header is longer than its limit"
            case .missingContentLength: "a message header has no valid Content-Length"
            case .contentTooLong(let length): "a message announces \(length) bytes, more than its limit"
        }
    }
}

/// Splits a byte stream framed by the LSP base protocol into message bodies, however the stream is cut.
///
/// A frame is a header block of `Name: value` lines, each ended by CRLF, an empty line, and then exactly `Content-Length` bytes of body.
/// Header names are matched without regard to case and any header other than `Content-Length` is ignored. The end of a header block is
/// found with `memchr`, resuming where the last search stopped, and a body is never scanned: a megabyte body arriving in a thousand chunks
/// costs its copy and nothing more.
public struct ContentLengthFraming: Sendable {
    /// The default longest header block, in bytes.
    public static let defaultMaximumHeaderLength = 8 << 10
    /// The default longest body, in bytes.
    public static let defaultMaximumContentLength = 64 << 20

    public let maximumHeaderLength: Int
    public let maximumContentLength: Int

    private var buffer: [UInt8] = []
    /// Where the next frame starts in `buffer`; the bytes before it are consumed.
    private var start = 0
    /// Where the search for the end of the current header resumes.
    private var scanFrom = 0
    /// The current frame's body, once its header is read: where it starts and how long it is.
    private var body: (start: Int, length: Int)?
    /// Bytes examined while looking for the ends of headers, for the test that bodies are not scanned.
    private(set) var bytesScanned = 0

    public init(
        maximumHeaderLength: Int = defaultMaximumHeaderLength, maximumContentLength: Int = defaultMaximumContentLength
    ) {
        self.maximumHeaderLength = maximumHeaderLength
        self.maximumContentLength = maximumContentLength
    }

    /// `body` with its header.
    public static func frame(_ body: [UInt8]) -> [UInt8] {
        var bytes = Array("Content-Length: \(body.count)\r\n\r\n".utf8)
        bytes.reserveCapacity(bytes.count + body.count)
        bytes += body
        return bytes
    }

    /// Appends `bytes` and returns every body now complete, in order.
    /// - Throws: ``JSONRPCFramingError`` when the stream is not framed or passes a limit; the framing is unusable after.
    /// - Complexity: amortized O(*n*) in the bytes appended.
    public mutating func append(_ bytes: some Sequence<UInt8>) throws(JSONRPCFramingError) -> [[UInt8]] {
        buffer.append(contentsOf: bytes)
        var bodies: [[UInt8]] = []
        while let next = try next() { bodies.append(next) }
        if start > 0, start >= buffer.count / 2 { compact() }
        return bodies
    }

    private mutating func next() throws(JSONRPCFramingError) -> [UInt8]? {
        if body == nil {
            guard let separator = headerEnd() else {
                if buffer.count - start > maximumHeaderLength { throw .headerTooLong }
                return nil
            }
            guard separator - start <= maximumHeaderLength else { throw .headerTooLong }
            let length = try contentLength(start, separator)
            body = (separator + 4, length)
        }
        guard let (bodyStart, length) = body, buffer.count - bodyStart >= length else { return nil }
        let bytes = Array(buffer[bodyStart ..< bodyStart + length])
        start = bodyStart + length
        scanFrom = start
        body = nil
        return bytes
    }

    /// The index of the CRLF CRLF that ends the header at `start`, searching from `scanFrom` with `memchr` for each CR.
    private mutating func headerEnd() -> Int? {
        let cr = UInt8(ascii: "\r")
        var index = scanFrom
        while let found = firstIndex(of: cr, in: buffer, from: index) {
            guard found + 3 < buffer.count else {
                bytesScanned += found - scanFrom
                scanFrom = found
                return nil
            }
            if buffer[found + 1] == UInt8(ascii: "\n"), buffer[found + 2] == cr, buffer[found + 3] == UInt8(ascii: "\n")
            {
                bytesScanned += found + 4 - scanFrom
                scanFrom = found + 4
                return found
            }
            index = found + 1
        }
        bytesScanned += buffer.count - scanFrom
        scanFrom = buffer.count
        return nil
    }

    /// The `Content-Length` of the header in `buffer[from..<to]`.
    private func contentLength(_ from: Int, _ to: Int) throws(JSONRPCFramingError) -> Int {
        var lineStart = from
        while lineStart < to {
            // Every line of the block ends with CRLF, the last one at `to`, so the search always finds one by then.
            let lineEnd = min(firstIndex(of: UInt8(ascii: "\r"), in: buffer, from: lineStart) ?? to, to)
            if let length = try contentLength(line: lineStart, lineEnd) { return length }
            lineStart = lineEnd + 2
        }
        throw .missingContentLength
    }

    /// The value of the header line `buffer[from..<to]` if it is `Content-Length`, or nil for another header.
    private func contentLength(line from: Int, _ to: Int) throws(JSONRPCFramingError) -> Int? {
        let name = Array("content-length".utf8)
        guard to - from > name.count, buffer[from + name.count] == UInt8(ascii: ":") else { return nil }
        for offset in 0 ..< name.count where buffer[from + offset] | 0x20 != name[offset] { return nil }
        var index = from + name.count + 1
        while index < to, buffer[index] == UInt8(ascii: " ") || buffer[index] == UInt8(ascii: "\t") { index += 1 }
        var end = to
        while end > index, buffer[end - 1] == UInt8(ascii: " ") || buffer[end - 1] == UInt8(ascii: "\t") { end -= 1 }
        // Eighteen digits cannot overflow an `Int`, and any limit worth having is far below them.
        guard end > index, end - index <= 18 else { throw .missingContentLength }
        var length = 0
        for byte in buffer[index ..< end] {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { throw .missingContentLength }
            length = length * 10 + Int(byte - UInt8(ascii: "0"))
        }
        guard length <= maximumContentLength else { throw .contentTooLong(length) }
        return length
    }

    /// Drops the consumed bytes, keeping the offsets into the rest.
    private mutating func compact() {
        buffer.removeFirst(start)
        scanFrom -= start
        if let (bodyStart, length) = body { body = (bodyStart - start, length) }
        start = 0
    }
}

/// Splits a byte stream of one message per line into messages, however the stream is cut.
///
/// A line ends at LF; a CR before it is dropped, and a line holding only spaces, tabs or a CR is not a message. Newlines are found with
/// `memchr` in the new bytes only, so a line that arrives in many chunks is scanned once. A line longer than the limit is reported once,
/// as ``Line/tooLong``, its bytes are dropped up to its newline, and the lines after it are read as usual: the caller decides whether a
/// stream that sent one is still worth reading.
public struct LineFraming: Sendable {
    /// What a line is.
    public enum Line: Sendable, Equatable {
        /// A message, without its line ending.
        case message([UInt8])
        /// A line longer than the limit, dropped.
        case tooLong
    }

    /// The default longest line, in bytes.
    public static let defaultMaximumLineLength = 8 << 20

    public let maximumLineLength: Int

    /// The start of a line that has not ended yet.
    private var pending: [UInt8] = []
    /// Whether the line that has not ended yet is already too long, and being dropped.
    private var dropping = false
    /// Bytes examined, for the test that each is examined once.
    private(set) var bytesScanned = 0

    public init(maximumLineLength: Int = defaultMaximumLineLength) {
        self.maximumLineLength = maximumLineLength
    }

    /// `body` as a line. A body written by AemiJSON without pretty-printing holds no raw newline.
    public static func frame(_ body: [UInt8]) -> [UInt8] {
        var bytes = body
        bytes.append(UInt8(ascii: "\n"))
        return bytes
    }

    /// Takes `bytes` and returns the lines they complete, in order.
    /// - Complexity: O(*n*) in the bytes appended.
    public mutating func append(_ bytes: some Collection<UInt8>) -> [Line] {
        if let lines = bytes.withContiguousStorageIfAvailable({ unsafe append(contiguous: $0) }) { return lines }
        return Array(bytes).withUnsafeBufferPointer { unsafe append(contiguous: $0) }
    }

    private mutating func append(contiguous chunk: UnsafeBufferPointer<UInt8>) -> [Line] {
        var lines: [Line] = []
        var start = 0
        while let newline = unsafe firstIndex(of: UInt8(ascii: "\n"), in: chunk, from: start) {
            let segment = unsafe UnsafeBufferPointer(rebasing: chunk[start ..< newline])
            bytesScanned += newline + 1 - start
            if dropping {
                dropping = false
            } else if pending.count + segment.count > maximumLineLength {
                lines.append(.tooLong)
                pending.removeAll(keepingCapacity: true)
            } else if pending.isEmpty {
                unsafe Self.emit(segment, to: &lines)
            } else {
                unsafe pending.append(contentsOf: segment)
                pending.withUnsafeBufferPointer { unsafe Self.emit($0, to: &lines) }
                pending.removeAll(keepingCapacity: true)
            }
            start = newline + 1
        }
        let rest = chunk.count - start
        bytesScanned += rest
        guard !dropping, rest > 0 else { return lines }
        if pending.count + rest > maximumLineLength {
            lines.append(.tooLong)
            dropping = true
            pending = []
        } else {
            unsafe pending.append(contentsOf: UnsafeBufferPointer(rebasing: chunk[start...]))
        }
        return lines
    }

    /// Adds `line` to `lines` without a CR at its end, unless it is blank.
    private static func emit(_ line: UnsafeBufferPointer<UInt8>, to lines: inout [Line]) {
        var count = line.count
        if count > 0, unsafe line[count - 1] == UInt8(ascii: "\r") { count -= 1 }
        let blank = unsafe line[0 ..< count].allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
        guard !blank else { return }
        unsafe lines.append(.message(Array(line[0 ..< count])))
    }
}

/// The index of the first `byte` in `buffer` at or after `from`, found with `memchr`.
private func firstIndex(of byte: UInt8, in buffer: [UInt8], from: Int) -> Int? {
    buffer.withUnsafeBufferPointer { unsafe firstIndex(of: byte, in: $0, from: from) }
}

private func firstIndex(of byte: UInt8, in buffer: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
    guard from < buffer.count, let base = buffer.baseAddress else { return nil }
    let count = buffer.count - from
    let found = unsafe AemiKernels.firstIndexOfByte(base: base + from, count: count, needle: byte)
    return found == count ? nil : from + found
}
