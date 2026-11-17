// Where a node sits in the bytes it was parsed from, for a tool that changes one value and keeps the
// rest of a document as written (its comments, trailing commas and key style). Read from the tape:
// a scalar's slot carries its offset and length; a container's span is recorded under
// `JSONParseOptions.recordsContainerSpans`.
extension JSON {
    /// The byte range of this node's complete text in the parsed input: a container from its opening
    /// bracket through its closing one, a string with its quotes (escapes as written), a number or a
    /// literal as its lexeme. `nil` for a missing node, and for a container when the document was not
    /// parsed with ``JSONParseOptions/recordsContainerSpans``.
    public var sourceRange: Range<Int>? {
        guard index >= 0 else { return nil }
        switch tag {
            case JSONKind.object.rawValue, JSONKind.array.rawValue:
                return doc.containerSpans.span(ofContainerAt: index).map { $0.lowerBound ..< $0.upperBound + 1 }
            case JSONKind.string.rawValue:
                // The slot holds the text between the quotes; either quote JSON5 allows is one byte.
                return Slot.low(slot) - 1 ..< Slot.low(slot) + Slot.length(slot) + 1
            default:
                return Slot.low(slot) ..< Slot.low(slot) + Slot.length(slot)
        }
    }

    /// Visits each `(key, key's range, value)` member in document order, as ``forEachMember(_:)`` does,
    /// with the byte range of the key as written: its quotes included when it has them, the bare name
    /// for a JSON5 identifier key.
    public func forEachMemberWithKeyRange(_ body: (String, Range<Int>, JSON) -> Void) {
        unsafe forEachMemberSlot { p, i in
            let keySlot = doc.tape[i]
            let start = Slot.low(keySlot)
            let end = start + Slot.length(keySlot)
            // A quoted key's slot starts after its quote; a bare identifier is never preceded by one.
            let before: UInt8 = start > 0 ? unsafe p[start - 1] : 0
            let quoted = before == 0x22 || before == 0x27
            let key = JSON(doc: doc, index: i).string ?? ""
            body(key, quoted ? start - 1 ..< end + 1 : start ..< end, JSON(doc: doc, index: i + 1))
        }
    }
}
