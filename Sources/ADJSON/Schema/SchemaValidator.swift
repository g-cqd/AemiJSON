import Foundation

struct SchemaValidator {
    let nodes: [SchemaNode]
    let registry: [String: Int]

    func resolve(_ ref: String) -> Int? {
        var r = ref
        if r.hasPrefix("#") { r.removeFirst() }
        return registry[r]
    }

    // Recursion tracks schema-node depth plus instance depth; both are bounded by the parser's
    // `maxDepth` (512) for parsed inputs, so this cannot overflow the stack on documents produced
    // by `ADJSON.parse`. Local `$ref` cycles are broken via `activeRefs`.
    @discardableResult
    func validate(
        _ index: Int, _ instance: JSON, _ loc: String, _ errors: inout [ValidationError],
        _ activeRefs: Set<String> = []
    ) -> Bool {
        let node = nodes[index]

        if let b = node.boolean {
            if !b { errors.append(ValidationError(instanceLocation: loc, message: "schema is false")) }
            return b
        }

        var ok = true
        func fail(_ message: String) {
            ok = false
            errors.append(ValidationError(instanceLocation: loc, message: message))
        }
        func passes(_ subIndex: Int, _ value: JSON) -> Bool {
            var ignored = [ValidationError]()
            return validate(subIndex, value, loc, &ignored, activeRefs)
        }

        // Follow a local `$ref`, guarding against cycles (a → b → a) that would otherwise
        // recurse forever on the same instance. The key pairs the target subschema with the
        // instance location; re-entering the same pair is a cycle, so we stop — the result is
        // idempotent because the ancestor frame already validates this subschema here.
        if let ref = node.ref, let target = resolve(ref) {
            let key = "\(target)@\(loc)"
            if !activeRefs.contains(key), !validate(target, instance, loc, &errors, activeRefs.union([key])) {
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

        if instance.isNumberKind, let v = instance.double {
            if let m = node.minimum, v < m { fail("minimum") }
            if let m = node.maximum, v > m { fail("maximum") }
            if let m = node.exclusiveMinimum, v <= m { fail("exclusiveMinimum") }
            if let m = node.exclusiveMaximum, v >= m { fail("exclusiveMaximum") }
            if let mo = node.multipleOf, mo > 0 {
                let q = v / mo
                if (q.rounded() - q).magnitude > 1e-9 * Swift.max(1, q.magnitude) { fail("multipleOf") }
            }
        }

        if let s = instance.string {
            let len = s.unicodeScalars.count
            if let m = node.minLength, len < m { fail("minLength") }
            if let m = node.maxLength, len > m { fail("maxLength") }
            if let re = node.pattern, !re.matches(s) { fail("pattern") }
        }

        if instance.isArray, let elems = instance.array {
            if let m = node.minItems, elems.count < m { fail("minItems") }
            if let m = node.maxItems, elems.count > m { fail("maxItems") }
            if node.uniqueItems {
                var unique = true
                outer: for i in 0..<elems.count {
                    for j in (i + 1)..<elems.count where jsonSemanticEqual(elems[i], elems[j]) {
                        unique = false
                        break outer
                    }
                }
                if !unique { fail("uniqueItems") }
            }
            var prefixCount = 0
            if let pi = node.prefixItems {
                prefixCount = Swift.min(pi.count, elems.count)
                for i in 0..<prefixCount where !validate(pi[i], elems[i], loc + "/\(i)", &errors, activeRefs) {
                    ok = false
                }
            }
            if let it = node.items {
                for i in prefixCount..<elems.count where !validate(it, elems[i], loc + "/\(i)", &errors, activeRefs) {
                    ok = false
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

        if instance.isObject, let obj = instance.object {
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
                        if !validate(sub, v, loc + "/" + jsonPointerEscape(k), &errors, activeRefs) { ok = false }
                    }
                }
            }
            if let pp = node.patternProperties {
                for (re, sub) in pp {
                    for (k, v) in obj where re.matches(k) {
                        evaluated.insert(k)
                        if !validate(sub, v, loc + "/" + jsonPointerEscape(k), &errors, activeRefs) { ok = false }
                    }
                }
            }
            if let ap = node.additionalProperties {
                for (k, v) in obj where !evaluated.contains(k) {
                    if !validate(ap, v, loc + "/" + jsonPointerEscape(k), &errors, activeRefs) { ok = false }
                }
            }
            if let dr = node.dependentRequired {
                for (k, deps) in dr where obj[k] != nil {
                    for d in deps where obj[d] == nil { fail("dependentRequired: '\(k)' requires '\(d)'") }
                }
            }
            if let ds = node.dependentSchemas {
                for (k, sub) in ds where obj[k] != nil {
                    if !validate(sub, instance, loc, &errors, activeRefs) { ok = false }
                }
            }
        }

        if let all = node.allOf {
            for sub in all where !validate(sub, instance, loc, &errors, activeRefs) { ok = false }
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
                if let t = node.thenSchema, !validate(t, instance, loc, &errors, activeRefs) { ok = false }
            } else if let el = node.elseSchema, !validate(el, instance, loc, &errors, activeRefs) {
                ok = false
            }
        }

        return ok
    }
}
