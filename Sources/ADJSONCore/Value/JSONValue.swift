/// A fully-materialized, mutable JSON value tree. The lazy `JSON` view is read-only
/// over a parsed document; `JSONValue` is the editable counterpart used by JSON Patch
/// (RFC 6902) and JSON Merge Patch (RFC 7396).
///
/// Numbers are held as `Double`; integers beyond 2^53 lose precision (documented).
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
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
        var members = [String: JSONValue](minimumCapacity: json.count)
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
        if let d = json.double { return .number(d) }
        if let s = json.string { return .string(s) }
        if json.isArray || json.isObject { return nil }
        return .null  // missing sentinel materializes as null, matching the former recursion
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
        var object: [String: JSONValue]
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
                object = [String: JSONValue](minimumCapacity: c)
            } else {
                isObject = false
                var vs: [JSON] = []
                vs.reserveCapacity(c)
                node.forEachElement { vs.append($0) }
                nodes = vs
                keys = []
                array = []
                array.reserveCapacity(c)
                object = [:]
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

    /// The deepest array/object nesting `encoded()` will serialize before failing. Mirrors
    /// the parser's `maxDepth` so a value that round-trips through parse always re-encodes.
    static let maxEncodingDepth = 512

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

    // Number emission for the value model. Under `.swiftShortest` an integral magnitude below 2^53
    // is rendered without a fractional part (`2`, not `2.0`) so a JSON integer survives a
    // parse → `JSONValue` → `encoded()` round-trip unchanged — `JSONValue` only stores `Double`,
    // so it cannot otherwise tell `2` from `2.0`. This intentionally differs from the Codable
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
        }
    }
}
