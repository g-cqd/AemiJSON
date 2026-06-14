// A growable byte buffer with JSON formatting helpers. Reference type so the
// streaming encoder and the macro fast path can share one buffer as they recurse.
// Numbers are written straight into the buffer (no intermediate String for ints).
// `package` so the umbrella's Codable encoder (a separate module) can share it.
package final class JSONWriter {
    package var bytes: [UInt8]

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

    // Callers guarantee `v` is finite — the value paths pre-check and apply the non-finite policy
    // before reaching here, so this just writes the shortest `Double.description`.
    package func writeDouble(_ v: Double) {
        assert(v.isFinite, "JSONWriter.writeDouble requires a finite value")
        bytes.append(contentsOf: v.description.utf8)
    }

    // "key":
    package func writeKey(_ s: String) {
        writeString(s)
        bytes.append(0x3A)
    }

    package func writeString(_ s: String) { JSONOutput.appendString(s, to: &bytes) }
}
