// Serialize a lazy `JSON` cursor straight to UTF-8 bytes — compact, sorted, and/or pretty — without
// materializing a `JSONValue` tree. Output is byte-identical to `JSONValue(cursor).encodedBytes(...)`
// (it mirrors `JSONValue.writeIterative` and shares its `writeNumber`), so it is a drop-in, lower-
// allocation replacement for the encoder's pretty/sorted path and a useful accessor in its own right.

extension JSON {
    private enum WriteOp {
        case value(JSON, depth: Int)
        case key(String, pretty: Bool)
        case byte(UInt8)
        case indent(level: Int, comma: Bool)
    }

    /// Serialize this value to UTF-8 JSON bytes under `options` (number format, key order, pretty
    /// printing, slash / HTML escaping). Walks the tape iteratively, so it serializes any depth and
    /// allocates no intermediate value tree. Integer-shaped numbers within `Int64` keep full
    /// precision; other numbers follow `options.numberFormat` (matching ``JSONValue``).
    public func encodedBytes(options: JSONEncodingOptions = .rfc8259) throws -> [UInt8] {
        let writer = JSONWriter(capacity: 256)
        writer.escapeSlashes = options.escapeSlashes
        writer.escapeHTMLUnsafe = options.escapeHTMLUnsafe
        let pretty = options.prettyPrinted
        var stack: [WriteOp] = [.value(self, depth: 0)]
        while let op = stack.popLast() {
            switch op {
            case .byte(let b):
                writer.byte(b)
            case .key(let k, let pretty):
                if pretty { writer.writeKeyPretty(k) } else { writer.writeKey(k) }
            case .indent(let level, let comma):
                if comma { writer.byte(0x2C) }
                writer.newlineIndent(level)
            case .value(let node, let depth):
                guard depth <= JSONValue.maxEncodingDepth else {
                    throw EncodingError.invalidValue(
                        node, .init(codingPath: [], debugDescription: "Nesting exceeds \(JSONValue.maxEncodingDepth)"))
                }
                // Scalar dispatch mirrors `JSONValue.scalarValue` exactly: an integer-shaped token
                // within Int64 prints via `writeInteger`, every other number via the shared
                // `writeNumber` (so a fraction / out-of-Int64 integer collapses identically).
                if node.isNull {
                    writer.writeNull()
                } else if let b = node.bool {
                    writer.writeBool(b)
                } else if let i = node.integer(Int64.self) {
                    writer.writeInteger(i)
                } else if node.isNumberKind, let d = node.double {
                    try JSONValue.writeNumber(d, into: writer, options: options)
                } else if let s = node.string {
                    writer.writeString(s)
                } else if node.isArray {
                    let elements = node.arrayValue
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
                } else if node.isObject {
                    var pairs: [(String, JSON)] = []
                    pairs.reserveCapacity(node.count)
                    node.forEachMember { pairs.append(($0, $1)) }
                    if options.keyOrder == .sorted { pairs.sort { $0.0 < $1.0 } }
                    writer.byte(0x7B)
                    if pairs.isEmpty {
                        writer.byte(0x7D)
                    } else {
                        stack.append(.byte(0x7D))
                        if pretty { stack.append(.indent(level: depth, comma: false)) }
                        var i = pairs.count - 1
                        while i >= 0 {
                            stack.append(.value(pairs[i].1, depth: depth + 1))
                            stack.append(.key(pairs[i].0, pretty: pretty))
                            if pretty {
                                stack.append(.indent(level: depth + 1, comma: i > 0))
                            } else if i > 0 {
                                stack.append(.byte(0x2C))
                            }
                            i -= 1
                        }
                    }
                } else {
                    writer.writeNull()  // missing sentinel → null (matches scalarValue)
                }
            }
        }
        return writer.bytes
    }
}
