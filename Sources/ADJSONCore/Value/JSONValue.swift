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
    // numerically (`.int(5) == .number(5.0)`), so a hand-built `.number(5.0)` equals the `.int(5)` an
    // integer literal parses to. Objects compare by membership (unordered — not
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
            // `openKey` is non-nil exactly for an object frame (set in `advance` before each descend);
            // an array frame leaves it nil and folds positionally. Binding it avoids a force unwrap.
            if let openKey {
                object[openKey] = value
                self.openKey = nil
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
                // `key` is non-nil exactly for an object frame (see its binding above), so this routes
                // object members by key and array elements positionally without a force unwrap.
                if let key {
                    object[key] = scalar
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
    /// any recursive Swift value type, recurses and overflows around ~30–40k). Set far above the parse
    /// `maxDepth` so a value parsed with a high `maxDepth` still round-trips through `encoded()`.
    static let maxEncodingDepth = 1_000_000

    /// Serialize to compact UTF-8 JSON bytes using the given profile. The default (`.rfc8259`) is
    /// strict and throws `EncodingError.invalidValue` on a non-finite number; pass `.javaScript`
    /// for `JSON.stringify` byte-parity (non-finite → `null`, ECMA-262 number formatting). Also
    /// throws if the tree nests beyond `maxEncodingDepth`. The umbrella `ADJSON` module adds a
    /// `Data`-returning `encoded()` overload for Foundation interop.
    public func encodedBytes(options: JSONEncodingOptions = .rfc8259) throws -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(256)
        try write(into: &bytes, depth: 0, options: options)
        return bytes
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

    // Serialize straight into a value-type `[UInt8]` threaded `inout` — no class `JSONWriter`
    // indirection, so the buffer stays uniquely referenced and each append elides its copy-on-write
    // uniqueness check (the value-semantics win the `@JSONCodable` fast path already gets). The escape
    // policy rides along in `options`, applied per `JSONOutput.appendString` call. Compact +
    // declaration-order is the overwhelmingly common case and recurses directly; pretty/sorted output,
    // or any subtree past `maxFastDepth`, takes the iterative explicit-stack walk below, with
    // byte-identical output. `maxEncodingDepth` (a high policy ceiling) is enforced on the iterative
    // path; the recursive fast path hands off at `maxFastDepth` long before reaching it.
    func write(into bytes: inout [UInt8], depth: Int, options: JSONEncodingOptions) throws {
        if !options.prettyPrinted, options.keyOrder == .declaration {
            try writeCompact(self, into: &bytes, depth: depth, options: options)
        } else {
            try writeIterative(into: &bytes, depth: depth, options: options)
        }
    }

    private func writeCompact(
        _ value: JSONValue, into bytes: inout [UInt8], depth: Int, options: JSONEncodingOptions
    ) throws {
        switch value {
        case .null:
            JSONOutput.appendNull(to: &bytes)
        case .bool(let b):
            JSONOutput.appendBool(b, to: &bytes)
        case .int(let i):
            JSONOutput.appendInteger(i, to: &bytes)
        case .number(let d):
            try Self.writeNumber(d, into: &bytes, options: options)
        case .string(let s):
            JSONOutput.appendString(
                s, to: &bytes, escapeSlashes: options.escapeSlashes, escapeHTMLUnsafe: options.escapeHTMLUnsafe)
        case .array(let elements):
            bytes.append(0x5B)
            var first = true
            for element in elements {
                if !first { bytes.append(0x2C) }
                first = false
                try writeCompactChild(element, into: &bytes, depth: depth + 1, options: options)
            }
            bytes.append(0x5D)
        case .object(let members):
            bytes.append(0x7B)
            var first = true
            for (key, member) in members {
                if !first { bytes.append(0x2C) }
                first = false
                JSONOutput.appendString(
                    key, to: &bytes, escapeSlashes: options.escapeSlashes, escapeHTMLUnsafe: options.escapeHTMLUnsafe)
                bytes.append(0x3A)
                try writeCompactChild(member, into: &bytes, depth: depth + 1, options: options)
            }
            bytes.append(0x7D)
        }
    }

    @inline(__always)
    private func writeCompactChild(
        _ value: JSONValue, into bytes: inout [UInt8], depth: Int, options: JSONEncodingOptions
    ) throws {
        if depth >= Self.maxFastDepth {
            try value.writeIterative(into: &bytes, depth: depth, options: options)
        } else {
            try writeCompact(value, into: &bytes, depth: depth, options: options)
        }
    }

    func writeIterative(into bytes: inout [UInt8], depth: Int, options: JSONEncodingOptions) throws {
        // Explicit-stack preorder emission: containers push their closing byte, then their children
        // interleaved with separators in reverse, so a deeply nested tree serializes with no call
        // recursion. Output order is identical to the recursive `writeCompact`.
        let pretty = options.prettyPrinted
        let escapeSlashes = options.escapeSlashes
        let escapeHTMLUnsafe = options.escapeHTMLUnsafe
        var stack: [WriteOp] = [.value(self, depth: depth)]
        while let op = stack.popLast() {
            switch op {
            case .byte(let b):
                bytes.append(b)
            case .key(let k, let pretty):
                JSONOutput.appendString(k, to: &bytes, escapeSlashes: escapeSlashes, escapeHTMLUnsafe: escapeHTMLUnsafe)
                if pretty {
                    bytes.append(0x20)
                    bytes.append(0x3A)
                    bytes.append(0x20)  // `"k" : ` — space-colon-space
                } else {
                    bytes.append(0x3A)
                }
            case .indent(let level, let comma):
                if comma { bytes.append(0x2C) }
                bytes.append(0x0A)
                for _ in 0..<(level * 2) { bytes.append(0x20) }
            case .value(let value, let depth):
                guard depth <= Self.maxEncodingDepth else {
                    throw EncodingError.invalidValue(
                        value, .init(codingPath: [], debugDescription: "Nesting exceeds \(Self.maxEncodingDepth)"))
                }
                switch value {
                case .null:
                    JSONOutput.appendNull(to: &bytes)
                case .bool(let b):
                    JSONOutput.appendBool(b, to: &bytes)
                case .int(let i):
                    JSONOutput.appendInteger(i, to: &bytes)
                case .number(let d):
                    try Self.writeNumber(d, into: &bytes, options: options)
                case .string(let s):
                    JSONOutput.appendString(
                        s, to: &bytes, escapeSlashes: escapeSlashes, escapeHTMLUnsafe: escapeHTMLUnsafe)
                case .array(let elements):
                    bytes.append(0x5B)
                    if elements.isEmpty {
                        bytes.append(0x5D)
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
                    bytes.append(0x7B)
                    let pairs = options.keyOrder == .sorted ? members.sorted { $0.key < $1.key } : Array(members)
                    if pairs.isEmpty {
                        bytes.append(0x7D)
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

    // `Double`-case number emission. A parsed JSON integer within Int64 is held as `.int` and emitted
    // exactly via `writeInteger`, so this path only sees `.number(Double)` — a fraction, an exponent,
    // an out-of-Int64 integer, or a hand-built `.number(...)` — and renders it faithfully (`2.0`, never
    // bare `2`; a bare integer comes only from `.int`). The parse round-trip preserves the source's
    // int-vs-float shape: `"2"` parses to `.int` → `2`, `"2.0"` parses to `.number` → `2.0`. Shares
    // `JSONOutput.appendDouble` with the Codable streaming path, so all encoders agree. Use `.ecma262`
    // for `JSON.stringify` parity. `static` + `internal` so `JSON.encodedBytes` shares this formatting.
    static func writeNumber(_ d: Double, into bytes: inout [UInt8], options: JSONEncodingOptions) throws {
        try JSONOutput.appendDouble(d, options: options, to: &bytes)
    }
}
