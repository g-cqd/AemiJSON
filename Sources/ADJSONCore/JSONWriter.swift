// A growable byte buffer with JSON formatting helpers. Reference type so the
// streaming encoder and the macro fast path can share one buffer as they recurse.
// Numbers are written straight into the buffer (no intermediate String for ints).
// `package` so the umbrella's Codable encoder (a separate module) can share it.
package final class JSONWriter {
    package var bytes: [UInt8]
    /// String-escaping policy applied by ``writeString(_:)`` / ``writeKey(_:)``. Set from the encode
    /// options before serializing (default: minimal RFC 8259 escaping).
    package var escapeSlashes = false
    package var escapeHTMLUnsafe = false
    /// Pretty key separator emitted by ``writeKeyPretty(_:)``: `" : "` when `true` (Foundation,
    /// the default), `": "` when `false` (JavaScript `JSON.stringify`). Set from the encode options.
    package var prettySpaceBeforeColon = true

    package init(capacity: Int = 0) {
        bytes = []
        if capacity > 0 { bytes.reserveCapacity(capacity) }
    }

    package init(adopting buffer: [UInt8]) {
        bytes = buffer
        bytes.reserveCapacity(max(bytes.capacity, 1024))
    }

    @inline(__always) package func byte(_ b: UInt8) { bytes.append(b) }

    @inline(__always) package func raw(_ lit: StaticString) {
        lit.withUTF8Buffer { bytes.append(contentsOf: $0) }
    }

    package func writeNull() { JSONOutput.appendNull(to: &bytes) }

    package func writeBool(_ v: Bool) { JSONOutput.appendBool(v, to: &bytes) }

    @inline(__always) package func writeInteger<T: FixedWidthInteger>(_ v: T) {
        JSONOutput.appendInteger(v, to: &bytes)
    }

    // "key":
    package func writeKey(_ s: String) {
        writeString(s)
        bytes.append(0x3A)
    }

    // Pretty-print indent: newline + `level * 2` spaces. One definition shared by every serializer —
    // the eager `JSONValue` walk, the lazy `JSON` cursor, and the streaming Codable encoder — so the
    // indent width can't drift between them.
    @inline(__always) package func newlineIndent(_ level: Int) {
        bytes.append(0x0A)
        for _ in 0 ..< (level * 2) { bytes.append(0x20) }
    }

    // A pretty object key: `"key" : ` (Foundation) or `"key": ` (JS), per `prettySpaceBeforeColon`.
    @inline(__always) package func writeKeyPretty(_ s: String) {
        writeString(s)
        if prettySpaceBeforeColon { raw(" : ") } else { raw(": ") }
    }

    package func writeString(_ s: String) {
        JSONOutput.appendString(s, to: &bytes, escapeSlashes: escapeSlashes, escapeHTMLUnsafe: escapeHTMLUnsafe)
    }
}
