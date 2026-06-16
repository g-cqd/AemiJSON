public import OrderedCollections

/// A fully-materialized, mutable JSON value tree. The lazy `JSON` view is read-only
/// over a parsed document; `JSONValue` is the editable counterpart used by JSON Patch
/// (RFC 6902) and JSON Merge Patch (RFC 7396).
///
/// An integer-shaped number that fits a signed 64-bit `Int64` is held losslessly as ``int(_:)`` —
/// so a 64-bit ID like `9223372036854775807` survives a parse → encode round-trip exactly. Other
/// numbers (fractions, exponents, and magnitudes beyond `Int64`, e.g. a `UInt64 > Int64.max`) are
/// held as ``number(_:)`` (`Double`) and lose precision above 2^53, as documented. `.int(n)` and
/// `.number(Double(n))` compare equal, so the two integer spellings interoperate.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(OrderedDictionary<String, JSONValue>)
}

extension JSONValue {
    // Custom value equality. `.int` and `.number` are the same JSON number domain, so they compare
    // numerically (`.int(5) == .number(5.0)`), which keeps every hand-built `.number(...)` test in
    // step with parsed integers (now `.int`). Objects compare by membership (unordered — not
    // `OrderedDictionary`'s order-sensitive `==`).
    //
    // The walk is **iterative**: a work-stack of value pairs replaces structural recursion, so
    // comparing two deeply nested trees can't overflow the call stack. Order doesn't affect the result.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        var stack: [(JSONValue, JSONValue)] = [(lhs, rhs)]
        while let (a, b) = stack.popLast() {
            switch (a, b) {
            case (.null, .null): continue
            case let (.bool(x), .bool(y)): if x != y { return false }
            case let (.int(x), .int(y)): if x != y { return false }
            case let (.number(x), .number(y)): if x != y { return false }
            case let (.int(x), .number(y)): if Double(x) != y { return false }
            case let (.number(x), .int(y)): if x != Double(y) { return false }
            case let (.string(x), .string(y)): if x != y { return false }
            case let (.array(x), .array(y)):
                if x.count != y.count { return false }
                for i in 0..<x.count { stack.append((x[i], y[i])) }
            case let (.object(x), .object(y)):
                if x.count != y.count { return false }
                for (key, value) in x {
                    guard let other = y[key] else { return false }
                    stack.append((value, other))
                }
            default: return false
            }
        }
        return true
    }
}

extension JSONValue {
    /// The recursion-depth budget for `init(_:)`. Real-world JSON nests only a few levels, so the
    /// fast direct-recursion path handles essentially everything; only a document parsed with a large
    /// `maxDepth` that actually nests beyond this falls back to the iterative builder.
    private static let maxFastDepth = 128

    /// Materialize from a lazy `JSON` view.
    ///
    /// Direct recursion is the fast path: it inserts straight into the result `Array`/`Dictionary`
    /// with no per-container intermediate buffers. Beyond `maxFastDepth` it hands the subtree to an
    /// explicit-stack builder so a document parsed with a large `maxDepth` can't overflow the call
    /// stack (the common shallow case never pays for that safety).
    public init(_ json: JSON) {
        self = JSONValue.materialize(json, depth: 0)
    }

    private static func materialize(_ json: JSON, depth: Int) -> JSONValue {
        if let scalar = scalarValue(json) { return scalar }
        if depth >= maxFastDepth { return buildIteratively(json) }
        if json.isArray {
            var elements = [JSONValue]()
            elements.reserveCapacity(json.count)
            json.forEachElement { elements.append(materialize($0, depth: depth + 1)) }
            return .array(elements)
        }
        var members = OrderedDictionary<String, JSONValue>(minimumCapacity: json.count)
        json.forEachMember { members[$0] = materialize($1, depth: depth + 1) }
        return .object(members)
    }

    /// Materialize a container subtree with an explicit frame stack — no call recursion, so depth is
    /// unbounded. Used only past `maxFastDepth`.
    private static func buildIteratively(_ root: JSON) -> JSONValue {
        var stack = [BuildFrame(root)]
        var completed: JSONValue?
        while !stack.isEmpty {
            let top = stack.count - 1
            if let child = completed {
                completed = nil
                stack[top].fold(child)
            }
            switch stack[top].advance() {
            case .scalarAdded:
                continue
            case .descend(let node):
                stack.append(BuildFrame(node))
            case .done:
                completed = stack[top].finished
                stack.removeLast()
            }
        }
        return completed ?? .null
    }

    /// A scalar (or the missing sentinel), or `nil` when `json` is a container to be walked.
    private static func scalarValue(_ json: JSON) -> JSONValue? {
        if json.isNull { return .null }
        if let b = json.bool { return .bool(b) }
        // An integer-shaped token within Int64 keeps full precision as `.int`; a fraction/exponent,
        // or a magnitude beyond Int64, parses to `nil` here and falls through to the `Double` model.
        if let i = json.integer(Int64.self) { return .int(i) }
        if let d = json.double { return .number(d) }
        if let s = json.string { return .string(s) }
        if json.isArray || json.isObject { return nil }
        return .null  // a missing sentinel materializes as null
    }

    /// One in-progress container in the iterative materializer. Children are walked in document
    /// order via a forward cursor (`next`); `openKey` holds the object key whose (container) value
    /// is currently being built one frame deeper.
    private struct BuildFrame {
        enum Step { case scalarAdded, descend(JSON), done }

        let isObject: Bool
        let nodes: [JSON]
        let keys: [String]
        var next = 0
        var array: [JSONValue]
        var object: OrderedDictionary<String, JSONValue>
        var openKey: String?

        init(_ node: JSON) {
            let c = node.count
            if node.isObject {
                isObject = true
                var ks: [String] = []
                var vs: [JSON] = []
                ks.reserveCapacity(c)
                vs.reserveCapacity(c)
                node.forEachMember { k, v in
                    ks.append(k)
                    vs.append(v)
                }
                keys = ks
                nodes = vs
                array = []
                object = OrderedDictionary<String, JSONValue>(minimumCapacity: c)
            } else {
                isObject = false
                var vs: [JSON] = []
                vs.reserveCapacity(c)
                node.forEachElement { vs.append($0) }
                nodes = vs
                keys = []
                array = []
                array.reserveCapacity(c)
                object = [:]  // OrderedDictionary empty literal
            }
        }

        /// Fold a finished child container into this frame under the remembered `openKey`.
        mutating func fold(_ value: JSONValue) {
            if isObject {
                object[openKey!] = value
                openKey = nil
            } else {
                array.append(value)
            }
        }

        /// Consume the next child: scalars are added in place; a container is handed back to descend.
        mutating func advance() -> Step {
            guard next < nodes.count else { return .done }
            let node = nodes[next]
            let key = isObject ? keys[next] : nil
            next += 1
            if let scalar = JSONValue.scalarValue(node) {
                if isObject {
                    object[key!] = scalar
                } else {
                    array.append(scalar)
                }
                return .scalarAdded
            }
            openKey = key
            return .descend(node)
        }

        var finished: JSONValue { isObject ? .object(object) : .array(array) }
    }

    public init(parsing string: String, options: JSONParseOptions = .strict) throws(JSONError) {
        self.init(try ADJSON.parse(string, options: options).root)
    }

    /// A generous policy ceiling on serialization nesting. `write` is *iterative* (see below), so it
    /// cannot overflow the stack at any depth — this cap only rejects pathological trees, and it sits
    /// far above the depth at which a `JSONValue` tree could even be held (its ARC deallocation, like
    /// any recursive Swift value type, recurses and overflows around ~30–40k). Raised well past the
    /// old 512 so a value parsed with a high `maxDepth` still round-trips through `encoded()`.
    static let maxEncodingDepth = 1_000_000

    /// Serialize to compact UTF-8 JSON bytes using the given profile. The default (`.rfc8259`) is
    /// strict and throws `EncodingError.invalidValue` on a non-finite number; pass `.javaScript`
    /// for `JSON.stringify` byte-parity (non-finite → `null`, ECMA-262 number formatting). Also
    /// throws if the tree nests beyond `maxEncodingDepth`. The umbrella `ADJSON` module adds a
    /// `Data`-returning `encoded()` overload for Foundation interop.
    public func encodedBytes(options: JSONEncodingOptions = .rfc8259) throws -> [UInt8] {
        let writer = JSONWriter(capacity: 256)
        try write(into: writer, depth: 0, options: options)
        return writer.bytes
    }

    /// One unit of serialization work on the explicit stack: emit a value, write an object key,
    /// emit a single structural byte, or (when pretty-printing) a newline-plus-indent — optionally
    /// preceded by a comma — at a nesting level.
    private enum WriteOp {
        case value(JSONValue, depth: Int)
        case key(String, pretty: Bool)
        case byte(UInt8)
        case indent(level: Int, comma: Bool)
    }

    func write(into writer: JSONWriter, depth: Int, options: JSONEncodingOptions) throws {
        // Compact + declaration-order is the overwhelmingly common case; a shallow tree serializes
        // fastest by direct recursion straight into the writer (no `WriteOp` buffering — the same
        // regression the eager-tree parse had). Pretty/sorted output, or any subtree past
        // `maxFastDepth`, takes the iterative walk below; a deep subtree is handed off to it
        // mid-recursion, so the call stack stays bounded and the emitted bytes are identical either
        // way. The only nesting limit is `maxEncodingDepth` (a high policy ceiling, see above),
        // enforced on the iterative path — the recursive fast path hands off at `maxFastDepth` long
        // before reaching it.
        if !options.prettyPrinted, options.keyOrder == .declaration {
            try writeCompact(self, into: writer, depth: depth, options: options)
        } else {
            try writeIterative(into: writer, depth: depth, options: options)
        }
    }

    // Direct-recursion compact serializer: emits scalars and containers straight into the writer.
    // A child at or past `maxFastDepth` is delegated to the iterative walk (same writer, same
    // bytes), so real-world shallow trees never pay the explicit-stack overhead and deep ones still
    // can't overflow the call stack.
    private func writeCompact(
        _ value: JSONValue, into writer: JSONWriter, depth: Int, options: JSONEncodingOptions
    ) throws {
        switch value {
        case .null:
            writer.writeNull()
        case .bool(let b):
            writer.writeBool(b)
        case .int(let i):
            writer.writeInteger(i)
        case .number(let d):
            try writeNumber(d, into: writer, options: options)
        case .string(let s):
            writer.writeString(s)
        case .array(let elements):
            writer.byte(0x5B)
            var first = true
            for element in elements {
                if !first { writer.byte(0x2C) }
                first = false
                try writeCompactChild(element, into: writer, depth: depth + 1, options: options)
            }
            writer.byte(0x5D)
        case .object(let members):
            writer.byte(0x7B)
            var first = true
            for (key, member) in members {
                if !first { writer.byte(0x2C) }
                first = false
                writer.writeKey(key)
                try writeCompactChild(member, into: writer, depth: depth + 1, options: options)
            }
            writer.byte(0x7D)
        }
    }

    @inline(__always)
    private func writeCompactChild(
        _ value: JSONValue, into writer: JSONWriter, depth: Int, options: JSONEncodingOptions
    ) throws {
        if depth >= Self.maxFastDepth {
            try value.writeIterative(into: writer, depth: depth, options: options)
        } else {
            try writeCompact(value, into: writer, depth: depth, options: options)
        }
    }

    func writeIterative(into writer: JSONWriter, depth: Int, options: JSONEncodingOptions) throws {
        // Explicit-stack preorder emission: containers push their closing byte, then their children
        // interleaved with separators in reverse, so a deeply nested tree serializes with no call
        // recursion. Output order is identical to the former recursive walk.
        let pretty = options.prettyPrinted
        var stack: [WriteOp] = [.value(self, depth: depth)]
        while let op = stack.popLast() {
            switch op {
            case .byte(let b):
                writer.byte(b)
            case .key(let k, let pretty):
                if pretty {
                    writer.writeString(k)
                    writer.raw(" : ")
                } else {
                    writer.writeKey(k)
                }
            case .indent(let level, let comma):
                if comma { writer.byte(0x2C) }
                writer.byte(0x0A)
                for _ in 0..<(level * 2) { writer.byte(0x20) }
            case .value(let value, let depth):
                guard depth <= Self.maxEncodingDepth else {
                    throw EncodingError.invalidValue(
                        value, .init(codingPath: [], debugDescription: "Nesting exceeds \(Self.maxEncodingDepth)"))
                }
                switch value {
                case .null:
                    writer.writeNull()
                case .bool(let b):
                    writer.writeBool(b)
                case .int(let i):
                    writer.writeInteger(i)
                case .number(let d):
                    try writeNumber(d, into: writer, options: options)
                case .string(let s):
                    writer.writeString(s)
                case .array(let elements):
                    writer.byte(0x5B)
                    if elements.isEmpty {
                        writer.byte(0x5D)
                    } else {
                        stack.append(.byte(0x5D))
                        if pretty { stack.append(.indent(level: depth, comma: false)) }
                        var i = elements.count - 1
                        while i >= 0 {
                            stack.append(.value(elements[i], depth: depth + 1))
                            if pretty {
                                stack.append(.indent(level: depth + 1, comma: i > 0))
                            } else if i > 0 {
                                stack.append(.byte(0x2C))
                            }
                            i -= 1
                        }
                    }
                case .object(let members):
                    writer.byte(0x7B)
                    let pairs = options.keyOrder == .sorted ? members.sorted { $0.key < $1.key } : Array(members)
                    if pairs.isEmpty {
                        writer.byte(0x7D)
                    } else {
                        stack.append(.byte(0x7D))
                        if pretty { stack.append(.indent(level: depth, comma: false)) }
                        var i = pairs.count - 1
                        while i >= 0 {
                            stack.append(.value(pairs[i].value, depth: depth + 1))
                            stack.append(.key(pairs[i].key, pretty: pretty))
                            if pretty {
                                stack.append(.indent(level: depth + 1, comma: i > 0))
                            } else if i > 0 {
                                stack.append(.byte(0x2C))
                            }
                            i -= 1
                        }
                    }
                }
            }
        }
    }

    // `Double`-case number emission. A parsed JSON integer within Int64 is held as `.int` and
    // emitted exactly via `writeInteger`, so this path only sees `.number(Double)` — a fraction, an
    // exponent, an out-of-Int64 integer, or a hand-built `.number(...)`. Under `.swiftShortest` an
    // integral `Double` magnitude below 2^53 is still rendered without a fractional part (`2`, not
    // `2.0`), so a hand-built `.number(2)` and an out-of-Int64 integer both round-trip as integers;
    // `.number` can't otherwise tell `2` from `2.0`. This intentionally differs from the Codable
    // encode path, where a value typed `Double` is faithfully rendered as `2.0` (see
    // `JSONEncodingOptions.NumberFormat.swiftShortest`). Neither path reproduces Foundation's
    // formatter byte-for-byte; use `.ecma262` for `JSON.stringify` parity.
    private func writeNumber(_ d: Double, into writer: JSONWriter, options: JSONEncodingOptions) throws {
        guard d.isFinite else {
            switch options.nonFinite {
            case .throw:
                throw EncodingError.invalidValue(
                    d, .init(codingPath: [], debugDescription: "Non-finite \(d) cannot be encoded as JSON"))
            case .null:
                writer.writeNull()
            case .stringLiterals(let pos, let neg, let nan):
                writer.writeString(d.isNaN ? nan : (d > 0 ? pos : neg))
            }
            return
        }
        switch options.numberFormat {
        case .ecma262:
            JSONOutput.appendECMANumber(d, to: &writer.bytes)
        case .swiftShortest:
            if d == d.rounded(), abs(d) < 9.007_199_254_740_992e15 {
                writer.writeInteger(Int64(d))
            } else {
                writer.writeDouble(d)
            }
        case .sqlitePrintfG:
            // No integer promotion: SQLite keeps a real a real (`5.0`), and `appendSQLitePrintfG`
            // already emits the `.0`.
            JSONOutput.appendSQLitePrintfG(d, to: &writer.bytes)
        }
    }
}
