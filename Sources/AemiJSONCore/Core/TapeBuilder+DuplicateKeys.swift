import AemiKernel

// Duplicate-key detection for `.throwError` (RFC 7493 / I-JSON). Split from Scanner.swift to keep the
// structural scan loop (the `TapeBuilder` type body) within the size gate.
extension TapeBuilder {
    // Two keys are one key when their DECODED bytes are equal, which is the equality a lookup applies
    // (`JSONKey.matches`), so a document accepted here has no two keys a lookup could confuse and the
    // unique-keys shortcut ("the first match is the only match") is sound. `a` and `\u0061` are one key.
    //
    // Keys are bucketed under a hash of their decoded bytes in O(1) expected time, which avoids the O(n²)
    // all-pairs scan a hostile object with many keys could exploit (DoS). The hash is Swift's `Hasher`
    // (SipHash), seeded randomly per process, so an attacker cannot precompute a flood of colliding keys to
    // force the O(bucket²) compare fallback.
    //
    // The common key has no escape: its raw bytes are its decoded bytes, so it is hashed and compared in
    // place, exactly as before. Only a key whose slot has the escape flag is decoded, into the one scratch
    // buffer `decodedKey`, and a previously seen escaped key is compared through the escape-aware
    // `unescapedEquals` (no second buffer, no allocation) only when its hash matched.
    mutating func recordKey(_ keyStart: Int, frame: Int) throws(JSONError) {
        let keySlot = slots[slots.count - 1]
        let offset = Slot.low(keySlot)
        let length = Slot.length(keySlot)
        let escaped = Slot.flags(keySlot) & 1 == 1
        var hasher = Hasher()
        if escaped {
            unsafe JSONString.appendUnescaped(p, offset, length, json5: json5, replacing: &decodedKey)
            decodedKey.withUnsafeBytes { unsafe hasher.combine(bytes: $0) }
        } else {
            unsafe hasher.combine(bytes: UnsafeRawBufferPointer(start: p + offset, count: length))
        }
        let hash = hasher.finalize()
        // Read the bucket for the collision check, then append in place. The `if let` binding is
        // released before the `default:` subscript mutates, so the stored array keeps refcount 1 and
        // the append doesn't copy-on-write the whole bucket on every key.
        if let bucket = stack[frame].seenKeys[hash] {
            let isDuplicate =
                escaped
                ? decodedKey.withUnsafeBufferPointer { unsafe bucketHoldsKey(bucket, decoded: $0) }
                : unsafe bucketHoldsKey(bucket, decoded: UnsafeBufferPointer(start: p + offset, count: length))
            if isDuplicate { throw JSONError.duplicateKey(at: keyStart) }
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
        stack[frame].seenKeys[hash, default: []].append(keySlot)
    }

    /// Whether any key in `bucket` (all sharing one hash) decodes to `decoded`.
    private func bucketHoldsKey(_ bucket: [UInt64], decoded: UnsafeBufferPointer<UInt8>) -> Bool {
        // `decoded` is the key's decoded bytes. An empty buffer may have no base address, so a valid pointer
        // stands in; it is never dereferenced for a zero count.
        let base = unsafe decoded.baseAddress ?? p
        for previous in bucket {
            let previousOffset = Slot.low(previous)
            let previousLength = Slot.length(previous)
            if Slot.flags(previous) & 1 == 0 {
                if previousLength == decoded.count,
                    unsafe previousLength == 0 || JSONKey.bytesEqual(p + previousOffset, base, previousLength)
                {
                    return true
                }
            } else if json5 {
                if unsafe JSONString.unescapedEqualsJSON5(p, previousOffset, previousLength, base, decoded.count) {
                    return true
                }
            } else if unsafe JSONString.unescapedEquals(p, previousOffset, previousLength, base, decoded.count) {
                return true
            }
        }
        return false
    }
}
