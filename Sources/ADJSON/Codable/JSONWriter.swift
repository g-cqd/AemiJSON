import Foundation

// A growable byte buffer with JSON formatting helpers. Reference type so the
// streaming encoder and the macro fast path can share one buffer as they recurse.
// Numbers are written straight into the buffer (no intermediate String for ints).
final class JSONWriter {
    var bytes: [UInt8]

    init(capacity: Int = 0) {
        bytes = []
        if capacity > 0 { bytes.reserveCapacity(capacity) }
    }

    init(adopting buffer: [UInt8]) {
        bytes = buffer
        bytes.reserveCapacity(max(bytes.capacity, 1024))
    }

    @inline(__always) func byte(_ b: UInt8) { bytes.append(b) }

    @inline(__always) func raw(_ lit: StaticString) {
        lit.withUTF8Buffer { bytes.append(contentsOf: $0) }
    }

    func writeNull() { JSONOutput.appendNull(to: &bytes) }

    func writeBool(_ v: Bool) { JSONOutput.appendBool(v, to: &bytes) }

    @inline(__always) func writeInteger<T: FixedWidthInteger>(_ v: T) {
        JSONOutput.appendInteger(v, to: &bytes)
    }

    // Callers guarantee `v` is finite — the value paths pre-check and apply the non-finite policy
    // before reaching here, so this just writes the shortest `Double.description`.
    func writeDouble(_ v: Double) {
        assert(v.isFinite, "JSONWriter.writeDouble requires a finite value")
        bytes.append(contentsOf: v.description.utf8)
    }

    // "key":
    func writeKey(_ s: String) {
        writeString(s)
        bytes.append(0x3A)
    }

    func writeString(_ s: String) { JSONOutput.appendString(s, to: &bytes) }
}
