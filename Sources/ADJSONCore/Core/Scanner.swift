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

    // One open container being built. Stands in for a recursive-descent call frame, so nesting
    // lives on the heap and arbitrarily deep input can never overflow the call stack.
    //
    // `seenKeys` is initialized `[:]` for every frame, including arrays. An empty Swift dictionary
    // literal is the shared empty-singleton — it allocates nothing until the first insert, and only
    // `recordKey` (objects, in `.throwError` mode) ever inserts — so array frames and the default
    // (no duplicate-check) path pay zero allocation here. (Measured: already optimal; left as-is.)
    struct Frame {
        let openIndex: Int
        var count: Int
        let isObject: Bool
        var seenKeys: [Int: [(offset: Int, length: Int)]]
    }

    init(_ p: UnsafePointer<UInt8>, _ n: Int, options: JSONParseOptions) {
        // Owner/lifetime/bounds: the caller (`ADJSON.parse`, inside `withUnsafeBufferPointer`) owns `p`
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
        self.slots = []
        slots.reserveCapacity(n / 4 + 8)
        stack.reserveCapacity(16)
    }

    mutating func build() throws(JSONError) -> ContiguousArray<UInt64> {
        skipWS()
        try parseValue()
        skipWS()
        if i != n { throw JSONError.trailingData(at: i) }
        return slots
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

    // JSON5 insignificant input: the usual whitespace, vertical-tab / form-feed, and `//` line and
    // `/* … */` block comments. A lone `/` is left for the value parser to reject. An unterminated
    // block comment consumes to EOF, so the parser then reports an unexpected end of input.
    mutating func skipWSAndCommentsJSON5() {
        while i < n {
            let c = unsafe p[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0B || c == 0x0C {
                i += 1
                continue
            }
            guard c == 0x2F, i + 1 < n else { break }  // '/'
            if unsafe p[i + 1] == 0x2F {  // '//' line comment
                i += 2
                while i < n, unsafe p[i] != 0x0A, unsafe p[i] != 0x0D { i += 1 }
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
    mutating func closeContainer(_ openIdx: Int, count: Int, isObject: Bool) throws(JSONError) {
        guard count <= Slot.auxMask, UInt64(slots.count) <= 0xFFFF_FFFF else { throw JSONError.documentTooLarge }
        let tag = isObject ? JSONKind.object.rawValue : JSONKind.array.rawValue
        slots[openIdx] = Slot.container(tag, count: count, next: slots.count)
    }

    // Detects duplicate keys (RFC 7493 / `.throwError`) in O(1) expected time by bucketing keys
    // under a hash of their raw bytes — avoiding the O(n²) all-pairs scan a hostile object with
    // many keys could exploit (DoS). Hash collisions fall back to a byte compare.
    //
    // The hash is Swift's `Hasher` (SipHash), seeded randomly per process, so an attacker cannot
    // precompute a flood of colliding keys to force the O(bucket²) byte-compare fallback (a fixed-seed
    // hash would be vulnerable to exactly that HashDoS).
    //
    // NOTE: keys are compared by their RAW (still-escaped) bytes, so two keys equal only after
    // unescaping (`"a"` vs `"a"`) are NOT reported as duplicates. This is a deliberate perf
    // tradeoff — no per-key unescape on the scan path — and is acceptable under RFC 8259 (which
    // leaves duplicate handling to the application); RFC 7493 I-JSON producers emit canonical keys.
    mutating func recordKey(_ keyStart: Int, frame: Int) throws(JSONError) {
        let keySlot = slots[slots.count - 1]
        let offset = Slot.low(keySlot)
        let length = Slot.length(keySlot)
        var hasher = Hasher()
        unsafe hasher.combine(bytes: UnsafeRawBufferPointer(start: p + offset, count: length))
        let hash = hasher.finalize()
        // Read the bucket for the collision check, then append in place. The `if let` binding is
        // released before the `default:` subscript mutates, so the stored array keeps refcount 1 and
        // the append doesn't copy-on-write the whole bucket on every key.
        if let bucket = stack[frame].seenKeys[hash] {
            for previous in bucket
            where unsafe previous.length == length
                && (length == 0 || JSONKey.bytesEqual(p + previous.offset, p + offset, length))
            {
                throw JSONError.duplicateKey(at: keyStart)
            }
        }
        // Reserve the per-frame `seenKeys` once, on the object's first key, so the dictionary skips the
        // 1→2→4… rehash chain it would otherwise pay as each distinct key grows it. The scanner is
        // single-pass, so the object's *total* member count isn't in hand here (it's only final at the
        // closing `}`), and pre-scanning it would cost an extra O(members) walk; a small fixed reserve
        // covers the common small/medium object in one allocation without over-allocating a 1-key one,
        // and larger objects grow from there as before. `isEmpty` makes this fire exactly once per
        // object frame (array frames never call `recordKey`). Capacity never affects which key throws or
        // when, so the duplicate-key semantics stay byte-for-byte identical.
        if stack[frame].seenKeys.isEmpty {
            stack[frame].seenKeys.reserveCapacity(8)
        }
        stack[frame].seenKeys[hash, default: []].append((offset, length))
    }
}
