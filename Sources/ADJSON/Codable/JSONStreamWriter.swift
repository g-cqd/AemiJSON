/// A low-level, value-type streaming JSON writer whose byte output matches JavaScript
/// `JSON.stringify` (default `options: .javaScript`): no insignificant whitespace, `,`/`:`
/// separators, JS string escaping, ECMA-262 number formatting, and JS `null` semantics.
/// Emission order is exactly the caller's call order — no key sorting and no de-duplication.
/// It auto-inserts separators so call sequences can't desync, and reuses the same `JSONOutput`
/// byte layer as the encoder. `~Copyable` so `finish()` moves the buffer out with no copy and
/// accidental copy-on-write of the buffer is a compile error.
///
/// A deliberate JS-parity profile that sits beside ADJSON's RFC-8259-strict encoders, not a
/// replacement for them.
public struct JSONStreamWriter: ~Copyable {
    private var bytes: [UInt8]
    private var stack: [Frame]
    private var afterKey = false
    private let options: JSONEncodingOptions

    private struct Frame {
        let isObject: Bool
        var count: Int
    }

    public init(capacity: Int = 0, options: JSONEncodingOptions = .javaScript) {
        bytes = []
        if capacity > 0 { bytes.reserveCapacity(capacity) }
        stack = []
        stack.reserveCapacity(8)
        self.options = options
    }

    // MARK: Output

    /// Moves the finished buffer out (no copy). The writer is consumed.
    public consuming func finish() -> [UInt8] { bytes }

    /// Borrowing access to the buffer so far — e.g. to write straight into a `NIO.ByteBuffer`
    /// with no intermediate `[UInt8]` copy.
    public borrowing func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }

    // MARK: Separator state machine

    /// Emits the `,` that precedes a value when needed and accounts for it. A value that follows a
    /// `key(_:)` is already counted/separated by the key, so `afterKey` short-circuits it.
    @inline(__always) private mutating func separateBeforeValue() {
        if afterKey {
            afterKey = false
            return
        }
        let last = stack.count - 1
        if last >= 0 {
            if stack[last].count > 0 { bytes.append(0x2C) }
            stack[last].count += 1
        }
    }

    // MARK: Structure

    public mutating func beginObject() {
        separateBeforeValue()
        stack.append(Frame(isObject: true, count: 0))
        bytes.append(0x7B)
    }

    public mutating func endObject() {
        if !stack.isEmpty { stack.removeLast() }
        bytes.append(0x7D)
    }

    public mutating func beginArray() {
        separateBeforeValue()
        stack.append(Frame(isObject: false, count: 0))
        bytes.append(0x5B)
    }

    public mutating func endArray() {
        if !stack.isEmpty { stack.removeLast() }
        bytes.append(0x5D)
    }

    /// An escaped object key followed by `:`, in the caller's order (no sort, no de-duplication).
    public mutating func key(_ k: String) {
        let last = stack.count - 1
        if last >= 0 {
            if stack[last].count > 0 { bytes.append(0x2C) }
            stack[last].count += 1
        }
        JSONOutput.appendString(k, to: &bytes, escapeSlashes: options.escapeSlashes)
        bytes.append(0x3A)
        afterKey = true
    }

    // MARK: Values

    public mutating func string(_ s: String) {
        separateBeforeValue()
        JSONOutput.appendString(s, to: &bytes, escapeSlashes: options.escapeSlashes)
    }

    public mutating func stringOrNull(_ s: String?) {
        separateBeforeValue()
        if let s {
            JSONOutput.appendString(s, to: &bytes, escapeSlashes: options.escapeSlashes)
        } else {
            JSONOutput.appendNull(to: &bytes)
        }
    }

    public mutating func integer<T: FixedWidthInteger>(_ v: T) {
        separateBeforeValue()
        JSONOutput.appendInteger(v, to: &bytes)
    }

    /// A `Double`, formatted per `options.numberFormat`. Non-finite values (`NaN`/`±Infinity`)
    /// follow `options.nonFinite` — `null` under the `.javaScript` default, matching `JSON.stringify`
    /// (the writer never throws on a number).
    public mutating func number(_ v: Double) {
        separateBeforeValue()
        guard v.isFinite else {
            if case .stringLiterals(let pos, let neg, let nan) = options.nonFinite {
                let lit = v.isNaN ? nan : (v > 0 ? pos : neg)
                JSONOutput.appendString(lit, to: &bytes, escapeSlashes: options.escapeSlashes)
            } else {
                JSONOutput.appendNull(to: &bytes)
            }
            return
        }
        switch options.numberFormat {
        case .ecma262: JSONOutput.appendECMANumber(v, to: &bytes)
        case .swiftShortest: bytes.append(contentsOf: v.description.utf8)
        }
    }

    public mutating func bool(_ v: Bool) {
        separateBeforeValue()
        JSONOutput.appendBool(v, to: &bytes)
    }

    public mutating func null() {
        separateBeforeValue()
        JSONOutput.appendNull(to: &bytes)
    }

    // MARK: Verbatim splice (caller guarantees valid COMPACT JSON; counted as one value)

    public mutating func raw(_ utf8: some Sequence<UInt8>) {
        separateBeforeValue()
        bytes.append(contentsOf: utf8)
    }

    public mutating func raw(_ json: String) { raw(json.utf8) }

    /// The fragment, or `[]` when nil.
    public mutating func rawOrEmptyArray(_ json: String?) {
        separateBeforeValue()
        if let json {
            bytes.append(contentsOf: json.utf8)
        } else {
            bytes.append(0x5B)
            bytes.append(0x5D)
        }
    }

    /// The fragment, or `null` when nil.
    public mutating func rawOrNull(_ json: String?) {
        separateBeforeValue()
        if let json {
            bytes.append(contentsOf: json.utf8)
        } else {
            JSONOutput.appendNull(to: &bytes)
        }
    }

    /// Validates the fragment is well-formed JSON (via the tape parser) before splicing it, for
    /// untrusted input. Throws `JSONError` on malformed input; does not re-canonicalize, so the
    /// fragment should already be compact for byte-exactness.
    public mutating func rawValidated(_ json: String) throws(JSONError) {
        _ = try ADJSON.parse(json)
        separateBeforeValue()
        bytes.append(contentsOf: json.utf8)
    }
}
