import ADJSONCore

// Per-keyword validation groups for `SchemaValidator.validate`, split out so the core dispatcher stays
// within the size/complexity gate. Each `validate…` returns whether its group passed and appends any
// `ValidationError`s; the recursive groups (array items, object members, applicators) thread
// `path`/`errors` + the `ValidationContext` and re-enter `validate`. Behaviour is identical to the
// former single-function form — the JSON-Schema compliance suite covers every keyword here.
extension SchemaValidator {
    // Validate a subschema against `value` discarding its errors — used by the applicators
    // (anyOf / oneOf / not / if) and `contains`, which need only a pass/fail, not the diagnostics. The
    // location prefix is the caller's `path` (a copy: `validate` restores it anyway, so by-value is
    // exact and frees the call sites from threading an `inout`).
    private func passes(_ subIndex: Int, _ value: JSON, _ path: [String], _ ctx: ValidationContext) -> Bool {
        var ignored: [ValidationError] = []
        var p = path
        return validate(subIndex, value, &p, &ignored, ctx.deeper())
    }

    // Follow a local `$ref`, guarding against a → b → a cycles that would otherwise recurse forever on
    // the same instance location. A missing or already-active ref is a no-op (the ancestor frame
    // already validates this subschema here), so it contributes nothing to `ok`.
    func validateRef(
        _ node: SchemaNode, _ instance: JSON, _ path: inout [String], _ errors: inout [ValidationError],
        _ ctx: ValidationContext
    ) -> Bool {
        guard let ref = node.ref, let target = resolve(ref) else { return true }
        let key = "\(target)@\(location(path))"
        guard !ctx.activeRefs.contains(key) else { return true }
        return validate(target, instance, &path, &errors, ctx.entering(key))
    }

    // `type` / `const` / `enum`.
    func validateTypeConstEnum(
        _ node: SchemaNode, _ instance: JSON, _ path: [String], _ errors: inout [ValidationError]
    ) -> Bool {
        var ok = true
        func fail(_ message: String) {
            ok = false
            errors.append(ValidationError(instanceLocation: location(path), message: message))
        }
        if let types = node.types, !types.contains(where: { instance.matchesSchemaType($0) }) {
            fail("type: expected one of \(types.map(\.rawValue))")
        }
        if let c = node.constValue, !jsonSemanticEqual(instance, c) { fail("const: value not equal") }
        if let e = node.enumValues, !e.contains(where: { jsonSemanticEqual(instance, $0) }) {
            fail("enum: value not allowed")
        }
        return ok
    }

    // Numeric bounds. Only parses the number when a numeric keyword is present — otherwise a typed
    // schema (`{"type":"number"}`) would pay `strtod` on every value for nothing.
    func validateNumericBounds(
        _ node: SchemaNode, _ instance: JSON, _ path: [String], _ errors: inout [ValidationError]
    ) -> Bool {
        let hasNumericBound =
            node.minimum != nil || node.maximum != nil || node.exclusiveMinimum != nil
            || node.exclusiveMaximum != nil || node.multipleOf != nil
        guard hasNumericBound, instance.isNumberKind, let v = instance.double else { return true }
        var ok = true
        func fail(_ message: String) {
            ok = false
            errors.append(ValidationError(instanceLocation: location(path), message: message))
        }
        if let m = node.minimum, v < m { fail("minimum") }
        if let m = node.maximum, v > m { fail("maximum") }
        if let m = node.exclusiveMinimum, v <= m { fail("exclusiveMinimum") }
        if let m = node.exclusiveMaximum, v >= m { fail("exclusiveMaximum") }
        if let mo = node.multipleOf, violatesMultipleOf(v, mo) { fail("multipleOf") }
        return ok
    }

    // Exact integer modulo when both operands are integral and exactly representable (|x| < 2^53); a
    // relative-epsilon test only for genuine fractions. The float `q = v / mo` path gives FALSE
    // NEGATIVES for large integers (at v ≈ 10^12 the tolerance `1e-9 * |q|` grows to ~10^3, so a
    // non-multiple within that band wrongly passes), so it is confined to fractions where an exact
    // modulo isn't meaningful.
    private func violatesMultipleOf(_ v: Double, _ mo: Double) -> Bool {
        guard mo > 0 else { return false }
        if let iv = Self.exactInteger(v), let im = Self.exactInteger(mo) {
            return iv % im != 0
        }
        let q = v / mo
        return (q.rounded() - q).magnitude > 1e-9 * Swift.max(1, q.magnitude)
    }

    // String length / pattern — only materializes the String when a string keyword needs it.
    func validateStringBounds(
        _ node: SchemaNode, _ instance: JSON, _ path: [String], _ errors: inout [ValidationError]
    ) -> Bool {
        guard node.minLength != nil || node.maxLength != nil || node.pattern != nil,
            let s = instance.string
        else { return true }
        var ok = true
        func fail(_ message: String) {
            ok = false
            errors.append(ValidationError(instanceLocation: location(path), message: message))
        }
        let len = s.unicodeScalars.count
        if let m = node.minLength, len < m { fail("minLength") }
        if let m = node.maxLength, len > m { fail("maxLength") }
        if let re = node.pattern, !re.matches(s) { fail("pattern") }
        return ok
    }

    // Array keywords: minItems / maxItems / uniqueItems / prefixItems / items / contains.
    func validateArray(
        _ node: SchemaNode, _ instance: JSON, _ path: inout [String], _ errors: inout [ValidationError],
        _ ctx: ValidationContext
    ) -> Bool {
        guard let elems = instance.array else { return true }
        var ok = true
        func fail(_ message: String) {
            ok = false
            errors.append(ValidationError(instanceLocation: location(path), message: message))
        }
        if let m = node.minItems, elems.count < m { fail("minItems") }
        if let m = node.maxItems, elems.count > m { fail("maxItems") }
        if node.uniqueItems, hasDuplicates(elems) { fail("uniqueItems") }
        var prefixCount = 0
        if let pi = node.prefixItems {
            prefixCount = Swift.min(pi.count, elems.count)
            for i in 0 ..< prefixCount {
                path.append(String(i))
                if !validate(pi[i], elems[i], &path, &errors, ctx.deeper()) { ok = false }
                path.removeLast()
            }
        }
        if let it = node.items {
            for i in prefixCount ..< elems.count {
                path.append(String(i))
                if !validate(it, elems[i], &path, &errors, ctx.deeper()) { ok = false }
                path.removeLast()
            }
        }
        if let cont = node.contains {
            var matched = 0
            for e in elems where passes(cont, e, path, ctx) { matched += 1 }
            let minC = node.minContains ?? 1
            if matched < minC { fail("contains: matched \(matched), need \(minC)") }
            if let maxC = node.maxContains, matched > maxC {
                fail("contains: matched \(matched) > maxContains \(maxC)")
            }
        }
        return ok
    }

    // O(n)-expected `uniqueItems`: bucket elements by a semantic hash (consistent with
    // `jsonSemanticEqual`), confirming with the full pairwise compare only on a hash collision — so a
    // hostile array can't force the naive all-pairs O(n²) scan (itself O(element size) per compare).
    // The hash is random-seeded (`Hasher`), so a collision flood can't be precomputed.
    private func hasDuplicates(_ elems: [JSON]) -> Bool {
        var seen: [Int: [Int]] = [:]
        for i in 0 ..< elems.count {
            let h = semanticHash(elems[i])
            if let bucket = seen[h] {
                for j in bucket where jsonSemanticEqual(elems[i], elems[j]) { return true }
            }
            seen[h, default: []].append(i)
        }
        return false
    }

    // Object keywords. Fast path (a struct-style schema with no patternProperties / additionalProperties
    // and no property-count bounds) validates required / properties / dependents through the lazy
    // cursor, avoiding a materialized `[String: JSON]` per object; otherwise the full path materializes
    // `instance.object` to track the evaluated-properties set additionalProperties needs.
    func validateObject(
        _ node: SchemaNode, _ instance: JSON, _ path: inout [String], _ errors: inout [ValidationError],
        _ ctx: ValidationContext
    ) -> Bool {
        if node.patternProperties == nil, node.additionalProperties == nil,
            node.minProperties == nil, node.maxProperties == nil
        {
            return validateObjectFast(node, instance, &path, &errors, ctx)
        }
        return validateObjectFull(node, instance, &path, &errors, ctx)
    }

    private func validateObjectFast(
        _ node: SchemaNode, _ instance: JSON, _ path: inout [String], _ errors: inout [ValidationError],
        _ ctx: ValidationContext
    ) -> Bool {
        var ok = true
        func fail(_ message: String) {
            ok = false
            errors.append(ValidationError(instanceLocation: location(path), message: message))
        }
        if let req = node.required {
            for r in req where !instance[r].exists { fail("required: missing '\(r)'") }
        }
        if let props = node.properties {
            for (k, sub) in props {
                let v = instance[k]
                if v.exists {
                    path.append(jsonPointerEscape(k))
                    if !validate(sub, v, &path, &errors, ctx.deeper()) { ok = false }
                    path.removeLast()
                }
            }
        }
        if !validateDependents(node, instance, &path, &errors, ctx, has: { instance[$0].exists }) { ok = false }
        return ok
    }

    private func validateObjectFull(
        _ node: SchemaNode, _ instance: JSON, _ path: inout [String], _ errors: inout [ValidationError],
        _ ctx: ValidationContext
    ) -> Bool {
        guard let obj = instance.object else { return true }
        var ok = true
        func fail(_ message: String) {
            ok = false
            errors.append(ValidationError(instanceLocation: location(path), message: message))
        }
        if let req = node.required {
            for r in req where obj[r] == nil { fail("required: missing '\(r)'") }
        }
        if let m = node.minProperties, obj.count < m { fail("minProperties") }
        if let m = node.maxProperties, obj.count > m { fail("maxProperties") }
        if !validateObjectMembers(node, obj, &path, &errors, ctx) { ok = false }
        if !validateDependents(node, instance, &path, &errors, ctx, has: { obj[$0] != nil }) { ok = false }
        return ok
    }

    // properties / patternProperties / additionalProperties, tracking which members each matched so
    // additionalProperties applies only to the leftovers.
    private func validateObjectMembers(
        _ node: SchemaNode, _ obj: [String: JSON], _ path: inout [String],
        _ errors: inout [ValidationError], _ ctx: ValidationContext
    ) -> Bool {
        var ok = true
        var evaluated = Set<String>()
        if let props = node.properties {
            for (k, sub) in props {
                if let v = obj[k] {
                    evaluated.insert(k)
                    path.append(jsonPointerEscape(k))
                    if !validate(sub, v, &path, &errors, ctx.deeper()) { ok = false }
                    path.removeLast()
                }
            }
        }
        if let pp = node.patternProperties {
            for (re, sub) in pp {
                for (k, v) in obj where re.matches(k) {
                    evaluated.insert(k)
                    path.append(jsonPointerEscape(k))
                    if !validate(sub, v, &path, &errors, ctx.deeper()) { ok = false }
                    path.removeLast()
                }
            }
        }
        if let ap = node.additionalProperties {
            for (k, v) in obj where !evaluated.contains(k) {
                path.append(jsonPointerEscape(k))
                if !validate(ap, v, &path, &errors, ctx.deeper()) { ok = false }
                path.removeLast()
            }
        }
        return ok
    }

    // dependentRequired / dependentSchemas. `has` decides member presence (cursor `instance[k].exists`
    // on the fast path, `obj[k] != nil` on the full path) so both object paths share this logic.
    private func validateDependents(
        _ node: SchemaNode, _ instance: JSON, _ path: inout [String], _ errors: inout [ValidationError],
        _ ctx: ValidationContext, has: (String) -> Bool
    ) -> Bool {
        var ok = true
        func fail(_ message: String) {
            ok = false
            errors.append(ValidationError(instanceLocation: location(path), message: message))
        }
        if let dr = node.dependentRequired {
            for (k, deps) in dr where has(k) {
                for d in deps where !has(d) { fail("dependentRequired: '\(k)' requires '\(d)'") }
            }
        }
        if let ds = node.dependentSchemas {
            for (k, sub) in ds where has(k) {
                if !validate(sub, instance, &path, &errors, ctx.deeper()) { ok = false }
            }
        }
        return ok
    }

    // Boolean applicators: allOf / anyOf / oneOf / not / if-then-else.
    func validateApplicators(
        _ node: SchemaNode, _ instance: JSON, _ path: inout [String], _ errors: inout [ValidationError],
        _ ctx: ValidationContext
    ) -> Bool {
        var ok = true
        func fail(_ message: String) {
            ok = false
            errors.append(ValidationError(instanceLocation: location(path), message: message))
        }
        let here = path  // applicators discard sub-errors, so they validate at the current location
        if let all = node.allOf {
            for sub in all where !validate(sub, instance, &path, &errors, ctx.deeper()) { ok = false }
        }
        if let any = node.anyOf, !any.contains(where: { passes($0, instance, here, ctx) }) {
            fail("anyOf: matched none")
        }
        if let one = node.oneOf {
            let matches = one.reduce(into: 0) { if passes($1, instance, here, ctx) { $0 += 1 } }
            if matches != 1 { fail("oneOf: matched \(matches), need exactly 1") }
        }
        if let n = node.not, passes(n, instance, here, ctx) {
            fail("not: must not match")
        }
        if let ic = node.ifSchema {
            if passes(ic, instance, here, ctx) {
                if let t = node.thenSchema, !validate(t, instance, &path, &errors, ctx.deeper()) { ok = false }
            } else if let el = node.elseSchema, !validate(el, instance, &path, &errors, ctx.deeper()) {
                ok = false
            }
        }
        return ok
    }
}
