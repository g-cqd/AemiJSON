import ADJSONCore
import Foundation

struct SchemaValidator {
    let nodes: [SchemaNode]
    let registry: [String: Int]
    // A hard cap on validation recursion, independent of the parser's `maxDepth`. Validation
    // recurses on BOTH schema-node depth (allOf / $ref / if-then chains) and instance depth — a
    // recursive schema (e.g. a `$ref`-linked list type) descends one frame per instance level — so
    // a deep schema, OR an instance parsed with a large `maxDepth`, could otherwise overflow the
    // native stack with no catchable error. Past this depth we fail closed: record a
    // `ValidationError` and stop.
    //
    // Kept well below the decoder's `maxDecodeDepth` (2048): a `validate` frame is far heavier (it
    // copies a whole `SchemaNode` — ~30 optional fields — plus its `fail`/`passes` closures), so it
    // overflows the stack at a much shallower depth (a deep recursive-schema validation overflowed a
    // small worker stack around ~50 frames in debug). 256 keeps a large margin on the ~8 MB main
    // thread in debug while staying far above any realistic schema/instance nesting; deeper inputs
    // fail closed. Lower it when validating untrusted input on a small-stack worker thread.
    var maxValidationDepth = 256

    func resolve(_ ref: String) -> Int? {
        var r = ref
        if r.hasPrefix("#") { r.removeFirst() }
        return registry[r]
    }

    // JSON Pointer for the current instance location. The location is threaded as a lightweight
    // segment stack and only rendered to a String when an error is actually recorded — a valid
    // document builds none.
    private func location(_ path: [String]) -> String {
        path.isEmpty ? "" : "/" + path.joined(separator: "/")
    }

    // `depth` counts every recursive entry (schema-structural and instance-descent alike). Local
    // `$ref` cycles (a → b → a at one instance location) are broken via `activeRefs`; unbounded
    // *acyclic* depth is bounded by `maxValidationDepth`.
    @discardableResult
    func validate(
        _ index: Int, _ instance: JSON, _ path: inout [String], _ errors: inout [ValidationError],
        _ activeRefs: Set<String> = [], _ depth: Int = 0
    ) -> Bool {
        guard depth <= maxValidationDepth else {
            errors.append(
                ValidationError(
                    instanceLocation: location(path),
                    message: "validation exceeded the maximum nesting depth (\(maxValidationDepth))"))
            return false
        }
        let node = nodes[index]

        if let b = node.boolean {
            if !b {
                errors.append(ValidationError(instanceLocation: location(path), message: "schema is false"))
            }
            return b
        }

        var ok = true
        func fail(_ message: String) {
            ok = false
            errors.append(ValidationError(instanceLocation: location(path), message: message))
        }
        func passes(_ subIndex: Int, _ value: JSON) -> Bool {
            var ignored = [ValidationError]()
            return validate(subIndex, value, &path, &ignored, activeRefs, depth + 1)
        }

        // Follow a local `$ref`, guarding against cycles (a → b → a) that would otherwise
        // recurse forever on the same instance. The key pairs the target subschema with the
        // instance location; re-entering the same pair is a cycle, so we stop — the result is
        // idempotent because the ancestor frame already validates this subschema here.
        if let ref = node.ref, let target = resolve(ref) {
            let key = "\(target)@\(location(path))"
            if !activeRefs.contains(key),
                !validate(target, instance, &path, &errors, activeRefs.union([key]), depth + 1)
            {
                ok = false
            }
        }

        if let types = node.types, !types.contains(where: { instance.matchesSchemaType($0) }) {
            fail("type: expected one of \(types.map(\.rawValue))")
        }
        if let c = node.constValue, !jsonSemanticEqual(instance, c) { fail("const: value not equal") }
        if let e = node.enumValues, !e.contains(where: { jsonSemanticEqual(instance, $0) }) {
            fail("enum: value not allowed")
        }

        // Only parse the number when a numeric keyword is present — otherwise a typed schema
        // (`{"type":"number"}`) would pay `strtod` on every value for nothing.
        let hasNumericBound =
            node.minimum != nil || node.maximum != nil || node.exclusiveMinimum != nil
            || node.exclusiveMaximum != nil || node.multipleOf != nil
        if hasNumericBound, instance.isNumberKind, let v = instance.double {
            if let m = node.minimum, v < m { fail("minimum") }
            if let m = node.maximum, v > m { fail("maximum") }
            if let m = node.exclusiveMinimum, v <= m { fail("exclusiveMinimum") }
            if let m = node.exclusiveMaximum, v >= m { fail("exclusiveMaximum") }
            if let mo = node.multipleOf, mo > 0 {
                // Exact integer modulo when both operands are integral and exactly representable
                // (|x| < 2^53). The float `q = v / mo` + relative-epsilon test gives FALSE NEGATIVES
                // for large integers: at, say, v ≈ 10^12 the tolerance `1e-9 * |q|` grows to ~10^3, so
                // a non-multiple within that band wrongly passes. Epsilon is kept only for genuine
                // fractions, where an exact modulo isn't meaningful.
                if let iv = Self.exactInteger(v), let im = Self.exactInteger(mo) {
                    if iv % im != 0 { fail("multipleOf") }
                } else {
                    let q = v / mo
                    if (q.rounded() - q).magnitude > 1e-9 * Swift.max(1, q.magnitude) { fail("multipleOf") }
                }
            }
        }

        // Likewise, only materialize the String when a string keyword needs it.
        if node.minLength != nil || node.maxLength != nil || node.pattern != nil, let s = instance.string {
            let len = s.unicodeScalars.count
            if let m = node.minLength, len < m { fail("minLength") }
            if let m = node.maxLength, len > m { fail("maxLength") }
            if let re = node.pattern, !re.matches(s) { fail("pattern") }
        }

        if instance.isArray, let elems = instance.array {
            if let m = node.minItems, elems.count < m { fail("minItems") }
            if let m = node.maxItems, elems.count > m { fail("maxItems") }
            if node.uniqueItems {
                // O(n) expected first pass: bucket elements by a semantic hash (consistent with
                // `jsonSemanticEqual`), confirming with the full pairwise compare only on a hash
                // collision. The all-pairs scan this replaces was O(n²) comparisons — each itself
                // O(element size) — a quadratic-×-deep DoS amplifier on a hostile array. The hash is
                // random-seeded (`Hasher`), so a flood of collisions can't be precomputed.
                var seen: [Int: [Int]] = [:]
                var unique = true
                outer: for i in 0..<elems.count {
                    let h = semanticHash(elems[i])
                    if let bucket = seen[h] {
                        for j in bucket where jsonSemanticEqual(elems[i], elems[j]) {
                            unique = false
                            break outer
                        }
                    }
                    seen[h, default: []].append(i)
                }
                if !unique { fail("uniqueItems") }
            }
            var prefixCount = 0
            if let pi = node.prefixItems {
                prefixCount = Swift.min(pi.count, elems.count)
                for i in 0..<prefixCount {
                    path.append(String(i))
                    if !validate(pi[i], elems[i], &path, &errors, activeRefs, depth + 1) { ok = false }
                    path.removeLast()
                }
            }
            if let it = node.items {
                for i in prefixCount..<elems.count {
                    path.append(String(i))
                    if !validate(it, elems[i], &path, &errors, activeRefs, depth + 1) { ok = false }
                    path.removeLast()
                }
            }
            if let cont = node.contains {
                var matched = 0
                for e in elems where passes(cont, e) { matched += 1 }
                let minC = node.minContains ?? 1
                if matched < minC { fail("contains: matched \(matched), need \(minC)") }
                if let maxC = node.maxContains, matched > maxC {
                    fail("contains: matched \(matched) > maxContains \(maxC)")
                }
            }
        }

        if instance.isObject {
            // Fast path for struct-style schemas: with no patternProperties/additionalProperties and
            // no property-count bounds, we never need a materialized member dictionary or an
            // `evaluated` set. Validate required/properties/dependents through the lazy cursor — this
            // avoids allocating a `[String: JSON]` per object (and the key Strings + hashing it costs),
            // which dominated validation throughput.
            if node.patternProperties == nil, node.additionalProperties == nil,
                node.minProperties == nil, node.maxProperties == nil
            {
                if let req = node.required {
                    for r in req where !instance[r].exists { fail("required: missing '\(r)'") }
                }
                if let props = node.properties {
                    for (k, sub) in props {
                        let v = instance[k]
                        if v.exists {
                            path.append(jsonPointerEscape(k))
                            if !validate(sub, v, &path, &errors, activeRefs, depth + 1) { ok = false }
                            path.removeLast()
                        }
                    }
                }
                if let dr = node.dependentRequired {
                    for (k, deps) in dr where instance[k].exists {
                        for d in deps where !instance[d].exists { fail("dependentRequired: '\(k)' requires '\(d)'") }
                    }
                }
                if let ds = node.dependentSchemas {
                    for (k, sub) in ds where instance[k].exists {
                        if !validate(sub, instance, &path, &errors, activeRefs, depth + 1) { ok = false }
                    }
                }
            } else if let obj = instance.object {
                if let req = node.required {
                    for r in req where obj[r] == nil { fail("required: missing '\(r)'") }
                }
                if let m = node.minProperties, obj.count < m { fail("minProperties") }
                if let m = node.maxProperties, obj.count > m { fail("maxProperties") }

                var evaluated = Set<String>()
                if let props = node.properties {
                    for (k, sub) in props {
                        if let v = obj[k] {
                            evaluated.insert(k)
                            path.append(jsonPointerEscape(k))
                            if !validate(sub, v, &path, &errors, activeRefs, depth + 1) { ok = false }
                            path.removeLast()
                        }
                    }
                }
                if let pp = node.patternProperties {
                    for (re, sub) in pp {
                        for (k, v) in obj where re.matches(k) {
                            evaluated.insert(k)
                            path.append(jsonPointerEscape(k))
                            if !validate(sub, v, &path, &errors, activeRefs, depth + 1) { ok = false }
                            path.removeLast()
                        }
                    }
                }
                if let ap = node.additionalProperties {
                    for (k, v) in obj where !evaluated.contains(k) {
                        path.append(jsonPointerEscape(k))
                        if !validate(ap, v, &path, &errors, activeRefs, depth + 1) { ok = false }
                        path.removeLast()
                    }
                }
                if let dr = node.dependentRequired {
                    for (k, deps) in dr where obj[k] != nil {
                        for d in deps where obj[d] == nil { fail("dependentRequired: '\(k)' requires '\(d)'") }
                    }
                }
                if let ds = node.dependentSchemas {
                    for (k, sub) in ds where obj[k] != nil {
                        if !validate(sub, instance, &path, &errors, activeRefs, depth + 1) { ok = false }
                    }
                }
            }
        }

        if let all = node.allOf {
            for sub in all where !validate(sub, instance, &path, &errors, activeRefs, depth + 1) { ok = false }
        }
        if let any = node.anyOf, !any.contains(where: { passes($0, instance) }) {
            fail("anyOf: matched none")
        }
        if let one = node.oneOf {
            let matches = one.reduce(into: 0) { if passes($1, instance) { $0 += 1 } }
            if matches != 1 { fail("oneOf: matched \(matches), need exactly 1") }
        }
        if let n = node.not, passes(n, instance) {
            fail("not: must not match")
        }
        if let ic = node.ifSchema {
            if passes(ic, instance) {
                if let t = node.thenSchema, !validate(t, instance, &path, &errors, activeRefs, depth + 1) { ok = false }
            } else if let el = node.elseSchema, !validate(el, instance, &path, &errors, activeRefs, depth + 1) {
                ok = false
            }
        }

        return ok
    }

    /// `d` as an `Int64` when it is integral and exactly representable as a `Double` (|d| < 2^53);
    /// `nil` for fractions or magnitudes where the `Double` itself is already lossy. Used by
    /// `multipleOf` to take an exact integer modulo instead of a lossy relative-epsilon test.
    static func exactInteger(_ d: Double) -> Int64? {
        guard d.rounded() == d, d.magnitude < 0x1p53 else { return nil }
        return Int64(d)
    }

    /// A hash consistent with `jsonSemanticEqual` (numbers by `Double` value, objects unordered,
    /// arrays ordered), used to bucket `uniqueItems` elements. Bounded-recursive: past
    /// `maxValidationDepth` it stops descending and emits a sentinel, so a deeply nested element
    /// can't overflow the stack — correctness is preserved because a hash collision is always
    /// confirmed by the (iterative) `jsonSemanticEqual`.
    func semanticHash(_ j: JSON) -> Int {
        var hasher = Hasher()
        hashValue(j, into: &hasher, depth: 0)
        return hasher.finalize()
    }

    private func hashValue(_ j: JSON, into hasher: inout Hasher, depth: Int) {
        guard depth <= maxValidationDepth else {
            hasher.combine(9)  // sentinel: deeper structure collides → confirmed by jsonSemanticEqual
            return
        }
        if j.isNull {
            hasher.combine(0)
        } else if let b = j.bool {
            hasher.combine(1)
            hasher.combine(b)
        } else if j.isNumberKind, let d = j.double {
            hasher.combine(2)
            hasher.combine(d)  // by Double value, matching jsonSemanticEqual (1 and 1.0 hash alike)
        } else if let s = j.string {
            hasher.combine(3)
            hasher.combine(s)
        } else if j.isArray {
            hasher.combine(4)
            hasher.combine(j.count)
            j.forEachElement { hashValue($0, into: &hasher, depth: depth + 1) }
        } else if j.isObject {
            hasher.combine(5)
            hasher.combine(j.count)
            // Order-independent: XOR each member's (key, value) hash so two objects that differ only
            // in key order hash alike, matching jsonSemanticEqual's unordered object equality.
            var acc = 0
            j.forEachMember { k, v in
                var member = Hasher()
                member.combine(k)
                hashValue(v, into: &member, depth: depth + 1)
                acc ^= member.finalize()
            }
            hasher.combine(acc)
        }
    }
}
