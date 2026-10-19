import OrderedCollections
import Testing

@testable import AemiJSON

// One document, every way AemiJSON can read it. The tape parser, the pull reader and the push reader are
// three implementations of one grammar (`Tokenizer.swift` says so, and the parity suites bind them); a
// conformance fix that lands in one of them and not the others is the bug these helpers exist to catch.
//
// A route reads bytes to the value they mean, or to `nil` when it rejects them. Comparing the *value*,
// not the error, keeps the routes free to report a rejection with their own error shape.

/// A way of reading a complete document.
enum ReadRoute: Sendable, CustomStringConvertible {
    /// `AemiJSON.parse`: the single-pass tape scanner.
    case tape
    /// `JSONEventReader`: the pull reader over the whole buffer.
    case pull
    /// `JSONEventStreamReader`, fed `chunkSize` bytes at a time.
    case push(chunkSize: Int)

    /// Every route, with the push reader at the chunk sizes that cut multi-byte tokens in different places.
    static let all: [ReadRoute] = [
        .tape, .pull, .push(chunkSize: 1), .push(chunkSize: 2), .push(chunkSize: 3), .push(chunkSize: 5),
        .push(chunkSize: 1 << 20)
    ]

    var description: String {
        switch self {
            case .tape: "tape"
            case .pull: "pull"
            case .push(let chunkSize): "push(\(chunkSize))"
        }
    }

    /// The value `bytes` reads as under `options`, or `nil` when this route rejects them.
    func value(of bytes: [UInt8], options: JSONParseOptions) -> JSONValue? {
        switch self {
            case .tape:
                guard let document = try? AemiJSON.parse(bytes, options: options) else { return nil }
                return JSONValue(document.root)
            case .pull:
                var reader = JSONEventReader(bytes, options: options)
                var events: [JSONEvent] = []
                do {
                    while let event = try reader.next() { events.append(event) }
                } catch {
                    return nil
                }
                return ReadRoute.value(of: events)
            case .push(let chunkSize):
                return ReadRoute.pushValue(of: bytes, chunkSize: chunkSize, options: options)
        }
    }

    /// The value the push reader produces when `bytes` arrive as consecutive `chunks`.
    static func pushValue(of bytes: [UInt8], chunks: [Range<Int>], options: JSONParseOptions) -> JSONValue? {
        var reader = JSONEventStreamReader(options: options)
        var events: [JSONEvent] = []
        do {
            for chunk in chunks { events.append(contentsOf: try reader.feed(Array(bytes[chunk]))) }
            events.append(contentsOf: try reader.finish())
        } catch {
            return nil
        }
        return value(of: events)
    }

    static func pushValue(of bytes: [UInt8], chunkSize: Int, options: JSONParseOptions) -> JSONValue? {
        var chunks: [Range<Int>] = []
        var start = 0
        while start < bytes.count {
            let end = Swift.min(start + chunkSize, bytes.count)
            chunks.append(start ..< end)
            start = end
        }
        return pushValue(of: bytes, chunks: chunks, options: options)
    }

    /// Folds a complete event stream into one root value, or `nil` when the stream is not exactly one value.
    static func value(of events: [JSONEvent]) -> JSONValue? {
        var position = 0
        func next() -> JSONValue? {
            guard position < events.count else { return nil }
            let event = events[position]
            position += 1
            switch event {
                case .null: return .null
                case .bool(let flag): return .bool(flag)
                case .number(let number): return .number(number)
                case .string(let text): return .string(text)
                case .beginArray:
                    var elements: [JSONValue] = []
                    while position < events.count {
                        if case .endArray = events[position] {
                            position += 1
                            return .array(elements)
                        }
                        guard let element = next() else { return nil }
                        elements.append(element)
                    }
                    return nil
                case .beginObject:
                    var members = OrderedDictionary<String, JSONValue>()
                    while position < events.count {
                        if case .endObject = events[position] {
                            position += 1
                            return .object(members)
                        }
                        guard case .key(let key) = events[position] else { return nil }
                        position += 1
                        guard let member = next() else { return nil }
                        members[key] = member
                    }
                    return nil
                case .endArray, .endObject, .key: return nil
            }
        }
        guard let root = next(), position == events.count else { return nil }
        return root
    }
}

/// Asserts every route reads `bytes` as `expected`, or rejects them when `expected` is `nil`.
func expectEveryRoute(
    _ bytes: [UInt8], options: JSONParseOptions = .json5, reads expected: JSONValue?,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for route in ReadRoute.all {
        let actual = route.value(of: bytes, options: options)
        #expect(
            actual == expected,
            "\(route) read \(describe(bytes)) as \(String(describing: actual)), expected \(String(describing: expected))",
            sourceLocation: sourceLocation)
    }
}

/// Asserts every route reads `text` as `expected`, or rejects it when `expected` is `nil`.
func expectEveryRoute(
    _ text: String, options: JSONParseOptions = .json5, reads expected: JSONValue?,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    expectEveryRoute(Array(text.utf8), options: options, reads: expected, sourceLocation: sourceLocation)
}

/// The bytes as hex with the printable ASCII kept readable, so a failure names the exact sequence.
func describe(_ bytes: [UInt8]) -> String {
    bytes.map { byte in
        (0x21 ... 0x7E).contains(byte) ? String(UnicodeScalar(byte)) : "\\x" + String(byte, radix: 16, uppercase: true)
    }
    .joined()
}
