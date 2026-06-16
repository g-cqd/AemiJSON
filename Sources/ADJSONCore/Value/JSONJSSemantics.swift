// Generic JavaScript value-coercion semantics over a lazy `JSON` node: truthiness and the
// ECMAScript `ToString` coercion. These are language-level coercions (what `if (value)` and
// `String(value)` do in JS), distinct from JSON serialization — they exist so hosts bridging JSON
// to JavaScript behavior don't re-derive the rules. Foundation-free; both are iterative.

extension JSON {
    /// JavaScript truthiness of this node (`Boolean(value)` / the `if (value)` test):
    /// `false`/`null`/`0`/`-0`/`NaN`/`""` and an absent (missing) node are falsy; every other number,
    /// non-empty string, and *every* array or object (including `[]` and `{}`) is truthy.
    public var isTruthy: Bool {
        switch tag {
        case JSONKind.boolTrue.rawValue:
            return true
        case JSONKind.boolFalse.rawValue, JSONKind.null.rawValue:
            return false
        case JSONKind.number.rawValue:
            guard let d = double else { return false }
            return d != 0 && !d.isNaN
        case JSONKind.string.rawValue:
            let len = Slot.length(slot)
            if len == 0 { return false }  // ""
            // Non-empty raw bytes decode to a non-empty string in every mode except JSON5, whose
            // line-continuation escapes (`\` + newline) elide to nothing; decode only that rare case
            // to stay exact (strict/lenient never reach it, so their fast path stays alloc-free).
            if doc.isJSON5 && Slot.flags(slot) & 1 == 1 { return !(string ?? "").isEmpty }
            return true
        case JSONKind.array.rawValue, JSONKind.object.rawValue:
            return true
        default:  // missing sentinel → `undefined` → falsy
            return false
        }
    }

    /// The ECMAScript `ToString` coercion of this node (`String(value)` in JavaScript): `null` and an
    /// absent node → `""`; `true`/`false` → `"true"`/`"false"`; a number → its
    /// ``JSONOutput/ecmaNumberToString(_:)`` form; a string → itself; an object → `"[object Object]"`;
    /// an array → its elements coerced and joined with `","` (`Array.prototype.join`'s default), so a
    /// nested array flattens its separators exactly as JS does.
    ///
    /// Note this is host *coercion*, not serialization — strings are not quoted and `null` becomes
    /// the empty string. For JSON output use the encoder.
    public var jsString: String {
        // Scalars (the overwhelming majority of coercion sites) need no walk.
        if tag != JSONKind.array.rawValue { return jsStringScalar }

        // Arrays join their elements with ",". An element that is itself an array expands in place,
        // so the work is driven by an explicit stack (no recursion): each popped item is either a
        // node to coerce-or-expand or a literal separator to emit.
        var out = ""
        var stack: [Item] = [.node(self)]
        while let item = stack.popLast() {
            switch item {
            case .separator:
                out.append(",")
            case .node(let node):
                if node.tag == JSONKind.array.rawValue {
                    let elements = node.arrayValue
                    guard let last = elements.last else { continue }  // [] contributes nothing
                    // Push so elements pop front-to-back with a separator between each: last element
                    // first (no trailing separator), then `, element` for each earlier one.
                    stack.append(.node(last))
                    var i = elements.count - 2
                    while i >= 0 {
                        stack.append(.separator)
                        stack.append(.node(elements[i]))
                        i -= 1
                    }
                } else {
                    out.append(node.jsStringScalar)
                }
            }
        }
        return out
    }

    // ECMAScript `ToString` for every node kind except array (handled iteratively by `jsString`).
    private var jsStringScalar: String {
        switch tag {
        case JSONKind.null.rawValue: return ""
        case JSONKind.boolTrue.rawValue: return "true"
        case JSONKind.boolFalse.rawValue: return "false"
        case JSONKind.number.rawValue: return jsNumberString ?? ""
        case JSONKind.string.rawValue: return string ?? ""
        case JSONKind.object.rawValue: return "[object Object]"
        default: return ""  // missing sentinel → `undefined` → ""
        }
    }

    private enum Item {
        case node(JSON)
        case separator
    }
}
