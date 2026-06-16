/// A lightweight, lazy view into a parsed JSON document: a reference to the
/// immutable `JSONDocument` plus a tape index. Navigation (`json.user.name`,
/// `json[0]`, `json["k"]`) walks the tape without materializing; concrete Swift
/// values are produced only when an accessor like `.string`/`.int` is read.
///
/// Missing values are represented by a sentinel (`index < 0`), so dotted access
/// chains never trap — `json.a.b.c.string` returns `nil` if any link is absent.
@dynamicMemberLookup
public struct JSON: Sendable {
    package let doc: JSONDocument
    let index: Int

    init(doc: JSONDocument, index: Int) {
        self.doc = doc
        self.index = index
    }

    static func missing(_ doc: JSONDocument) -> JSON { JSON(doc: doc, index: -1) }

    @inline(__always) var slot: UInt64 { doc.tape[index] }
    @inline(__always) var tag: UInt8 { index < 0 ? 0xFF : Slot.tag(slot) }

    // MARK: Presence / kind

    public var exists: Bool { index >= 0 }
    public var isNull: Bool { tag == JSONKind.null.rawValue }
    public var isObject: Bool { tag == JSONKind.object.rawValue }
    public var isArray: Bool { tag == JSONKind.array.rawValue }

    public var count: Int {
        (tag == JSONKind.object.rawValue || tag == JSONKind.array.rawValue) ? Slot.count(slot) : 0
    }

    // MARK: Scalars

    public var bool: Bool? {
        switch tag {
        case JSONKind.boolTrue.rawValue: return true
        case JSONKind.boolFalse.rawValue: return false
        default: return nil
        }
    }

    public var int: Int? {
        guard tag == JSONKind.number.rawValue, Slot.flags(slot) & 1 == 1 else { return nil }
        let off = Slot.low(slot), len = Slot.length(slot)
        return doc.withBytePointer { JSONNumber.parseInteger($0, off, len, Int.self) }
    }

    public var double: Double? {
        guard tag == JSONKind.number.rawValue else { return nil }
        let off = Slot.low(slot), len = Slot.length(slot)
        return doc.withBytePointer { JSONNumber.parseDouble($0, off, len) }
    }

    /// Parse the number as any fixed-width integer type (used by the decoder).
    func integer<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        guard tag == JSONKind.number.rawValue else { return nil }
        let off = Slot.low(slot), len = Slot.length(slot)
        return doc.withBytePointer { JSONNumber.parseInteger($0, off, len, T.self) }
    }

    public var float: Float? {
        guard let d = double else { return nil }
        return Float(d)
    }

    public var string: String? {
        guard tag == JSONKind.string.rawValue else { return nil }
        let off = Slot.low(slot), len = Slot.length(slot)
        let esc = Slot.flags(slot) & 1 == 1
        return doc.withBytePointer { p in
            if !esc { return String(decoding: UnsafeBufferPointer(start: p + off, count: len), as: UTF8.self) }
            return doc.isJSON5 ? JSONString.unescapeJSON5(p, off, len) : JSONString.unescape(p, off, len)
        }
    }

    // MARK: Zero-copy / alloc-free string access

    /// Compares this node's string value to `literal` by UTF-8 bytes, allocating **no** `String` on
    /// the common (unescaped) path — a fast equivalent of `string == literal.description` for the
    /// frequent "is this field named X?" / "is this value the literal Y?" tests. Returns `false` for
    /// any non-string node.
    ///
    /// Comparison is on the string's *decoded* content, so an escaped string node (rare for
    /// literal-like values) is unescaped once before comparing — the alloc-free guarantee holds only
    /// for unescaped nodes. The literal is matched as raw UTF-8, so non-ASCII literals work too.
    public func utf8Equals(_ literal: StaticString) -> Bool {
        guard tag == JSONKind.string.rawValue else { return false }
        let off = Slot.low(slot), len = Slot.length(slot)
        if Slot.flags(slot) & 1 == 1 {
            // JSON5's escape set requires the dedicated decoder, so it materializes once; strict/lenient
            // compare the decoded bytes on the fly via the alloc-free comparator.
            if doc.isJSON5 {
                let decoded = doc.withBytePointer { JSONString.unescapeJSON5($0, off, len) }
                return decoded == literal.description
            }
            return doc.withBytePointer {
                JSONString.unescapedEquals($0, off, len, literal.utf8Start, literal.utf8CodeUnitCount)
            }
        }
        // Unescaped fast path: raw byte compare against the literal's UTF-8, no allocation.
        guard len == literal.utf8CodeUnitCount else { return false }
        return doc.withBytePointer { p in JSONKey.bytesEqual(p + off, literal.utf8Start, len) }
    }

    /// Borrows the raw UTF-8 bytes of an **unescaped** string node for the duration of `body`,
    /// without allocating a `String`. Returns `nil` — and does not call `body` — for a non-string
    /// node *or* an escaped one (whose on-disk bytes still carry escape sequences); callers handle
    /// that case with ``string``, which decodes. The pointer is valid only within `body`; do not
    /// escape it.
    public func withUTF8Bytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R? {
        guard tag == JSONKind.string.rawValue, Slot.flags(slot) & 1 == 0 else { return nil }
        let off = Slot.low(slot), len = Slot.length(slot)
        return try doc.withBytePointer { p in
            try body(UnsafeRawBufferPointer(start: p + off, count: len))
        }
    }

    /// This number node rendered as an ECMAScript number string — the JavaScript `String(n)` /
    /// `JSON.stringify(n)` shortest-round-trip form (see ``JSONOutput/ecmaNumberToString(_:)``).
    /// `nil` for any non-number node. JSON5 `Infinity`/`NaN` literals render as `"Infinity"`/`"NaN"`.
    public var jsNumberString: String? {
        guard tag == JSONKind.number.rawValue, let d = double else { return nil }
        return JSONOutput.ecmaNumberToString(d)
    }

    // MARK: Containers

    public var array: [JSON]? {
        guard tag == JSONKind.array.rawValue else { return nil }
        let c = Slot.count(slot)
        var out = [JSON]()
        out.reserveCapacity(c)
        var i = index + 1
        for _ in 0..<c {
            out.append(JSON(doc: doc, index: i))
            i = nextIndex(after: i)
        }
        return out
    }

    public var object: [String: JSON]? {
        guard tag == JSONKind.object.rawValue else { return nil }
        let c = Slot.count(slot)
        var out = [String: JSON](minimumCapacity: c)
        doc.withBytePointer { p in
            var i = index + 1
            for _ in 0..<c {
                let k = doc.tape[i]
                let keyStr = decodeKey(p, k)
                out[keyStr] = JSON(doc: doc, index: i + 1)
                i = nextIndex(after: i + 1)
            }
        }
        return out
    }

    // MARK: Lazy walks (no intermediate collection)

    /// Visit each array element in order without materializing an intermediate `[JSON]`.
    public func forEachElement(_ body: (JSON) -> Void) {
        guard tag == JSONKind.array.rawValue else { return }
        let c = Slot.count(slot)
        var i = index + 1
        for _ in 0..<c {
            body(JSON(doc: doc, index: i))
            i = nextIndex(after: i)
        }
    }

    /// Visit each `(key, value)` member in document order without materializing an intermediate
    /// `[String: JSON]`. Duplicate keys are visited as they appear (callers that build a dictionary
    /// get last-value-wins for free).
    public func forEachMember(_ body: (String, JSON) -> Void) {
        guard tag == JSONKind.object.rawValue else { return }
        let c = Slot.count(slot)
        doc.withBytePointer { p in
            var i = index + 1
            for _ in 0..<c {
                let k = doc.tape[i]
                body(decodeKey(p, k), JSON(doc: doc, index: i + 1))
                i = nextIndex(after: i + 1)
            }
        }
    }

    // MARK: Subscripts / dynamic member lookup

    /// Look up an object member by key. Each lookup is an O(n) tape walk over the object's members
    /// (the tape is order-preserving, not hashed), so resolving many keys on the same object — or
    /// indexing the same array repeatedly — is O(n·k). For repeated random access, materialize the
    /// container once with ``object`` / ``array`` (each O(n), then O(1) per key/index) and read from
    /// the resulting `Dictionary`/`Array` instead.
    public subscript(key: String) -> JSON { member(key) }
    /// Look up an array element by index. O(n) in the element's position (the tape stores no offset
    /// index); see ``JSON/subscript(_:)`` for the materialize-once guidance on repeated access.
    public subscript(index idx: Int) -> JSON { element(idx) }
    public subscript(dynamicMember key: String) -> JSON { member(key) }

    // MARK: Non-optional convenience accessors

    public var stringValue: String { string ?? "" }
    public var intValue: Int { int ?? 0 }
    public var doubleValue: Double { double ?? 0 }
    public var boolValue: Bool { bool ?? false }
    public var arrayValue: [JSON] { array ?? [] }
    public var objectValue: [String: JSON] { object ?? [:] }

    // MARK: Navigation helpers

    // O(n) in the member count: an order-preserving linear scan, not a hash lookup. Callers doing
    // repeated random access should materialize once via `object` (see the subscript docs).
    private func member(_ key: String) -> JSON {
        guard tag == JSONKind.object.rawValue else { return .missing(doc) }
        let c = Slot.count(slot)
        let unique = doc.keysAreUnique  // unique keys → first match is the only match
        return doc.withBytePointer { p -> JSON in
            var i = index + 1
            var found = -1  // last match wins (consistent with `object` and JS / Foundation)
            for _ in 0..<c {
                let k = doc.tape[i]
                let valIdx = i + 1
                if keyMatches(p, k, key) {
                    found = valIdx
                    if unique { break }
                }
                i = nextIndex(after: valIdx)
            }
            return found >= 0 ? JSON(doc: doc, index: found) : .missing(doc)
        }
    }

    private func element(_ idx: Int) -> JSON {
        guard tag == JSONKind.array.rawValue, idx >= 0 else { return .missing(doc) }
        let c = Slot.count(slot)
        guard idx < c else { return .missing(doc) }
        var i = index + 1
        for _ in 0..<idx { i = nextIndex(after: i) }
        return JSON(doc: doc, index: i)
    }

    /// Append the elements selected by a Python-style slice (`start:end:step`, RFC 9535 semantics) to
    /// `out`, walking the tape once and stopping at the slice's upper bound — without materializing the
    /// whole array into a `[JSON]`. Negative `step` collects forward (the tape's only direction) and
    /// emits the matched range reversed.
    package func appendSlice(start: Int?, end: Int?, step: Int, into out: inout [JSON]) {
        guard tag == JSONKind.array.rawValue, step != 0 else { return }
        let len = Slot.count(slot)
        if len == 0 { return }
        func normalize(_ v: Int) -> Int { v >= 0 ? v : len + v }

        if step > 0 {
            let lower = Swift.min(Swift.max(start.map(normalize) ?? 0, 0), len)
            let upper = Swift.min(Swift.max(end.map(normalize) ?? len, 0), len)
            guard lower < upper else { return }
            var i = index + 1
            var p = 0
            while p < upper {
                if p >= lower && (p - lower) % step == 0 { out.append(JSON(doc: doc, index: i)) }
                i = nextIndex(after: i)
                p += 1
            }
        } else {
            let s = Swift.min(Swift.max(start.map(normalize) ?? (len - 1), -1), len - 1)
            let e = Swift.min(Swift.max(end.map(normalize) ?? (-len - 1), -1), len - 1)
            guard s > e else { return }
            // Walk forward to the lowest in-range position, then collect matches ascending and reverse
            // them into descending slice order.
            var i = index + 1
            var p = 0
            while p < e + 1 {
                i = nextIndex(after: i)
                p += 1
            }
            let mark = out.count
            while p <= s {
                if (s - p) % (-step) == 0 { out.append(JSON(doc: doc, index: i)) }
                i = nextIndex(after: i)
                p += 1
            }
            out[mark...].reverse()
        }
    }

    /// Index of the slot immediately after the value's whole subtree.
    @inline(__always)
    private func nextIndex(after node: Int) -> Int { Slot.next(after: node, doc.tape[node]) }

    @inline(__always)
    private func keyMatches(_ p: UnsafePointer<UInt8>, _ keySlot: UInt64, _ key: String) -> Bool {
        JSONKey.matches(p, Slot.low(keySlot), Slot.length(keySlot), escaped: Slot.flags(keySlot) & 1 == 1, key)
    }

    @inline(__always)
    private func decodeKey(_ p: UnsafePointer<UInt8>, _ keySlot: UInt64) -> String {
        let off = Slot.low(keySlot), len = Slot.length(keySlot)
        if Slot.flags(keySlot) & 1 == 1 {
            return doc.isJSON5 ? JSONString.unescapeJSON5(p, off, len) : JSONString.unescape(p, off, len)
        }
        return String(decoding: UnsafeBufferPointer(start: p + off, count: len), as: UTF8.self)
    }
}
