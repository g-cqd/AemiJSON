// `parseValue`'s structural helpers for `TapeBuilder`: opening a container (or closing an empty one),
// the JSON5 value-start dispatch, and folding a completed value up through its parents — closing each
// container the input ends. Split from Scanner.swift so the main scan loop stays within the
// size/complexity gate; the tape produced is identical.
extension TapeBuilder {
    // Opens `{`: reserves the container slot; an immediate `}` closes an empty object (a completed
    // value), otherwise pushes a frame and reads the first `key:`.
    mutating func openObject() throws(JSONError) -> Bool {
        if stack.count >= maxDepth { throw JSONError.depthExceeded(at: i) }
        let openIdx = slots.count
        slots.append(0)  // placeholder, patched at close
        i += 1
        skipWS()
        if unsafe i < n && p[i] == 0x7D {
            i += 1
            try closeContainer(openIdx, count: 0, isObject: true)
            return true
        }
        stack.append(Frame(openIndex: openIdx, count: 0, isObject: true, seenKeys: [:]))
        try readKeyColon()
        return false
    }

    // Opens `[`: reserves the container slot; an immediate `]` closes an empty array, otherwise pushes
    // a frame for the first element.
    mutating func openArray() throws(JSONError) -> Bool {
        if stack.count >= maxDepth { throw JSONError.depthExceeded(at: i) }
        let openIdx = slots.count
        slots.append(0)
        i += 1
        skipWS()
        if unsafe i < n && p[i] == 0x5D {
            i += 1
            try closeContainer(openIdx, count: 0, isObject: false)
            return true
        }
        stack.append(Frame(openIndex: openIdx, count: 0, isObject: false, seenKeys: [:]))
        return false
    }

    // The `default` value-start branch: a JSON5 single-quoted string, or a leading `+`/`.`/`Infinity`/
    // `NaN` number. Anything else is an unexpected character. (Strict/lenient starts are dispatched in
    // `parseValue`'s switch; this keeps the JSON5-only starts off that hot path.)
    mutating func scanJSON5ValueStart(_ c: UInt8) throws(JSONError) -> Bool {
        if json5, c == 0x27 {
            try scanString()
            return true
        }
        if json5, c == 0x2B || c == 0x2E || c == 0x49 || c == 0x4E {  // + . I(nfinity) N(aN)
            try scanNumber()
            return true
        }
        throw JSONError.unexpectedCharacter(c, at: i)
    }

    // Folds a just-completed value into its parent, closing each container the input ends. Returns true
    // when the completed value was the document root (so `parseValue` returns), false when a sibling
    // remains to be parsed.
    mutating func foldUp(_ initiallyCompleted: Bool) throws(JSONError) -> Bool {
        var completed = initiallyCompleted
        while completed {
            guard !stack.isEmpty else { return true }  // the completed value was the document root
            stack[stack.count - 1].count += 1
            skipWS()
            guard i < n else { throw JSONError.unexpectedEndOfInput }
            let sep = unsafe p[i]
            if stack[stack.count - 1].isObject {
                completed = try foldObjectSeparator(sep)
            } else {
                completed = try foldArraySeparator(sep)
            }
        }
        return false
    }

    // After an object member: `,` continues to the next `key:` (or, in JSON5, a trailing `,` before
    // `}` closes the object); `}` closes it. Returns whether the object is now itself a completed value.
    private mutating func foldObjectSeparator(_ sep: UInt8) throws(JSONError) -> Bool {
        if sep == 0x2C {
            i += 1
            if json5, trailingCommaClosesContainer(0x7D) {
                try closeTopContainer(isObject: true)
                return true
            }
            try readKeyColon()
            return false
        }
        if sep == 0x7D {
            i += 1
            try closeTopContainer(isObject: true)
            return true
        }
        throw JSONError.unexpectedCharacter(sep, at: i)
    }

    // After an array element: `,` continues to the next element (or, in JSON5, a trailing `,` before
    // `]` closes the array); `]` closes it. Returns whether the array is now a completed value.
    private mutating func foldArraySeparator(_ sep: UInt8) throws(JSONError) -> Bool {
        if sep == 0x2C {
            i += 1
            if json5, trailingCommaClosesContainer(0x5D) {
                try closeTopContainer(isObject: false)
                return true
            }
            return false
        }
        if sep == 0x5D {
            i += 1
            try closeTopContainer(isObject: false)
            return true
        }
        throw JSONError.unexpectedCharacter(sep, at: i)
    }

    // Pops the top frame and patches its container placeholder with the final count + subtree end.
    private mutating func closeTopContainer(isObject: Bool) throws(JSONError) {
        let frame = stack.removeLast()
        try closeContainer(frame.openIndex, count: frame.count, isObject: isObject)
    }
}
