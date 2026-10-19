import AemiKernel

// Single-pass, iterative (explicit-stack, non-recursive) scanner that builds the tape
// WITHOUT materializing any value. In strict mode it enforces the RFC 8259 grammar (number
// shape, escape validity, UTF-8 well-formedness); in lenient mode it scans permissively.
@safe struct TapeBuilder {
    let p: UnsafePointer<UInt8>
    let n: Int
    let strict: Bool
    let json5: Bool
    let checkDuplicates: Bool
    let enforceIEEE754Numbers: Bool
    let maxDepth: Int
    var i = 0
    var slots: ContiguousArray<UInt64>
    var stack: [Frame] = []
    /// Each container's source span, recorded only under `recordsContainerSpans`: started when the
    /// container opens, completed when it closes, and carried onto `JSONDocument` so
    /// `JSON.withRawJSONBytes` can borrow a container's raw text zero-copy. Scalars need no entry —
    /// their slots already carry offset+length.
    var spans = ContainerSpans()
    let recordSpans: Bool
    /// Scratch for the decoded bytes of an escaped object key under `.throwError` (see `recordKey`). It keeps
    /// its capacity across keys and stays empty, allocating nothing, until the first escaped key.
    var decodedKey = ContiguousArray<UInt8>()

    // One open container being built. Stands in for a recursive-descent call frame, so nesting
    // lives on the heap and arbitrarily deep input can never overflow the call stack.
    //
    // `seenKeys` is initialized `[:]` for every frame, including arrays. An empty Swift dictionary
    // literal is the shared empty-singleton — it allocates nothing until the first insert, and only
    // `recordKey` (objects, in `.throwError` mode) ever inserts — so array frames and the default
    // (no duplicate-check) path pay zero allocation here. (Measured: already optimal; left as-is.)
    struct Frame {
        let openIndex: Int
        /// This container's entry in `spans`, which the closing patch completes (-1 when spans are
        /// not recorded).
        let spanEntry: Int
        var count: Int
        let isObject: Bool
        /// The keys seen so far, bucketed by the hash of their decoded bytes; each entry is the key's own tape
        /// slot, which carries its offset, length and escape flag in 8 bytes.
        var seenKeys: [Int: [UInt64]]
    }

    init(_ p: UnsafePointer<UInt8>, _ n: Int, options: JSONParseOptions) {
        // Owner/lifetime/bounds: the caller (`AemiJSON.parse`, inside `withUnsafeBufferPointer`) owns `p`
        // for `p[0 ..< n]` and keeps it alive for this builder's whole lifetime; the builder reads only
        // within `[0, n)` (every access is guarded by `i < n`) and never lets `p` escape.
        assert(n >= 0, "TapeBuilder requires a non-negative byte count")
        unsafe self.p = p
        self.n = n
        self.strict = options.isStrict
        self.json5 = options.isJSON5
        self.checkDuplicates = options.duplicateKeys == .throwError
        self.enforceIEEE754Numbers = options.restrictsNumbersToIEEE754
        self.maxDepth = options.maxDepth
        self.recordSpans = options.recordsContainerSpans
        self.slots = []
        slots.reserveCapacity(n / 4 + 8)
        stack.reserveCapacity(16)
        // Room for one container per 64 input bytes, at 12 bytes an entry, so most documents record
        // their spans without regrowing (the benchmark corpora run from one container per 40 bytes to
        // one per 900).
        if recordSpans { spans.reserveCapacity(n / 64 + 8) }
    }

    mutating func build() throws(JSONError) -> (slots: ContiguousArray<UInt64>, spans: ContainerSpans) {
        // Skip a leading UTF-8 byte-order mark, which Foundation's decoder accepts and RFC 8259 §8.1
        // lets a parser ignore. Offsets stay relative to the buffer, so the tape still indexes the
        // caller's bytes.
        if n >= 3, unsafe p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF { i = 3 }
        skipWS()
        try parseValue()
        skipWS()
        if i != n { throw JSONError.trailingData(at: i) }
        return (slots, spans)
    }

    // Scalar whitespace skip — deliberately not SWAR. JSON whitespace runs are short (a newline + a
    // few indent spaces), so a word-at-a-time load + mask would sit on the parse critical path without
    // the 8-bytes-at-a-time payoff, whereas this scalar loop is branch-predictable and cache-resident.
    // Measured: SWAR regresses ~2.2× on realistic pretty-printed input (522 vs 1169 MB/s), so scalar
    // is the deliberate choice (measured, not assumed).
    @inline(__always) mutating func skipWS() {
        if json5 {
            skipWSAndCommentsJSON5()
            return
        }
        while i < n {
            let c = unsafe p[i]
            guard c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 else { break }
            i += 1
        }
    }

    // JSON5 insignificant input: the usual whitespace, vertical-tab / form-feed, the Unicode white space
    // JSON5 adds (`JSON5Whitespace`), and `//` line and `/* … */` block comments. A lone `/` is left for
    // the value parser to reject. A `//` comment ends at LF, CR, U+2028 or U+2029. An unterminated block
    // comment consumes to EOF, so the parser then reports an unexpected end of input.
    mutating func skipWSAndCommentsJSON5() {
        while i < n {
            let c = unsafe p[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0B || c == 0x0C {
                i += 1
                continue
            }
            if c >= 0x80 {
                // A multi-byte white-space character, or the first byte of significant input. The whole
                // buffer is in hand, so a sequence cut by its end is just invalid input for the parser.
                guard case .space(let length) = unsafe JSON5Whitespace.match(p, i, n) else { break }
                i += length
                continue
            }
            guard c == 0x2F, i + 1 < n else { break }  // '/'
            if unsafe p[i + 1] == 0x2F {  // '//' line comment
                i = unsafe JSON5Whitespace.lineCommentEnd(p, from: i + 2, count: n)
            } else if unsafe p[i + 1] == 0x2A {  // '/*' block comment
                i += 2
                while i + 1 < n, unsafe !(p[i] == 0x2A && p[i + 1] == 0x2F) { i += 1 }
                i = (i + 1 < n) ? i + 2 : n  // consume '*/', or run to EOF if unterminated
            } else {
                break  // lone '/'
            }
        }
    }

    // Iterative tape construction: an explicit `stack` of open containers stands in for recursive
    // descent, so nesting costs heap (O(depth)) rather than call-stack frames and can't overflow
    // the stack at any depth. The emitted tape is identical to what a recursive descent would produce.
    mutating func parseValue() throws(JSONError) {
        while true {
            // Positioned at the start of a value.
            skipWS()
            guard i < n else { throw JSONError.unexpectedEndOfInput }
            let c = unsafe p[i]
            let completed: Bool
            switch c {
                case 0x7B: completed = try openObject()  // '{'
                case 0x5B: completed = try openArray()  // '['
                case 0x22:
                    try scanString()
                    completed = true
                case 0x74, 0x66, 0x6E:
                    try scanLiteral()
                    completed = true
                case 0x2D, 0x30 ... 0x39:
                    try scanNumber()
                    completed = true
                default: completed = try scanJSON5ValueStart(c)
            }

            // Fold the completed value into its parent, closing each container the input ends; returns
            // true when that value was the document root (see TapeBuilder+Containers.swift).
            if try foldUp(completed) { return }
        }
    }

    // JSON5: after a comma, peek past whitespace/comments; if the next significant byte is the
    // container's closer, consume it (the comma was trailing) and report the container closed.
    mutating func trailingCommaClosesContainer(_ closer: UInt8) -> Bool {
        skipWS()
        if i < n, unsafe p[i] == closer {
            i += 1
            return true
        }
        return false
    }

    // Reads `"key":` for the current (top) object frame: key string + duplicate check + colon. In
    // JSON5 the key may also be single-quoted or an unquoted ECMAScript identifier.
    mutating func readKeyColon() throws(JSONError) {
        skipWS()
        let keyStart = i
        if json5, i < n, unsafe p[i] != 0x22, unsafe p[i] != 0x27 {
            try scanIdentifierKeyJSON5()  // unquoted identifier
        } else {
            guard i < n, unsafe p[i] == 0x22 || (json5 && p[i] == 0x27) else {
                throw JSONError.unexpectedCharacter(i < n ? unsafe p[i] : 0, at: i)
            }
            try scanString()  // quoted key ('…' handled in json5)
        }
        if checkDuplicates { try recordKey(keyStart, frame: stack.count - 1) }
        skipWS()
        guard i < n, unsafe p[i] == 0x3A else { throw JSONError.unexpectedCharacter(i < n ? unsafe p[i] : 0, at: i) }
        i += 1  // :
    }

    // Patches a container's placeholder with its element count and the index after its subtree.
    // `count` occupies the 28-bit aux field, `next` the low 32 bits — both bounded by the 4 GB
    // input cap, but guarded so a pathological count can't silently wrap and corrupt navigation.
    mutating func closeContainer(_ openIdx: Int, spanEntry: Int, count: Int, isObject: Bool) throws(JSONError) {
        guard count <= Slot.auxMask, UInt64(slots.count) <= 0xFFFF_FFFF else { throw JSONError.documentTooLarge }
        let tag = isObject ? JSONKind.object.rawValue : JSONKind.array.rawValue
        slots[openIdx] = Slot.container(tag, count: count, next: slots.count)
        // Every close path reaches here with `i` one past the closing bracket, so `i - 1` is the
        // bracket itself; the span is inclusive on both ends.
        if spanEntry >= 0 { spans.close(spanEntry, at: i - 1) }
    }

    /// Starts the span of the container opening at `i` with its slot at `openIdx`, returning the entry
    /// its close completes, or -1 when spans are not recorded.
    @inline(__always) mutating func openSpan(_ openIdx: Int) -> Int {
        recordSpans ? spans.open(tapeIndex: openIdx, at: i) : -1
    }
}
