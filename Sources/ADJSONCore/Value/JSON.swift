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
    /// index); see ``subscript(key:)`` for the materialize-once guidance on repeated access.
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
