import ADJSONCore
import Foundation

// The per-frame recursion state threaded through validation: the set of active `$ref` targets (to
// break a → b → a cycles) and the current nesting `depth` (bounded by `maxValidationDepth`). Bundled
// into one value so the recursive keyword validators stay within the parameter-count gate; immutable
// per frame, with `deeper()` / `entering(_:)` producing the child frame.
struct ValidationContext {
    var activeRefs: Set<String> = []
    var depth = 0
    func deeper() -> ValidationContext { ValidationContext(activeRefs: activeRefs, depth: depth + 1) }
    func entering(_ refKey: String) -> ValidationContext {
        ValidationContext(activeRefs: activeRefs.union([refKey]), depth: depth + 1)
    }
}

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
    // Kept well below the decoder's `maxDecodeDepth` (2048): a `validate` frame is heavy (it copies a
    // whole `SchemaNode` — ~30 optional fields — and the keyword groups it fans out to each build
    // their own `fail` closure), so it overflows the stack at a much shallower depth (a deep
    // recursive-schema validation overflowed a small worker stack around ~50 frames in debug). 256
    // keeps a large margin on the ~8 MB main thread in debug while staying far above any realistic
    // schema/instance nesting; deeper inputs fail closed. Lower it when validating untrusted input on
    // a small-stack worker thread.
    var maxValidationDepth = 256

    func resolve(_ ref: String) -> Int? {
        var r = ref
        if r.hasPrefix("#") { r.removeFirst() }
        return registry[r]
    }

    // JSON Pointer for the current instance location. The location is threaded as a lightweight
    // segment stack and only rendered to a String when an error is actually recorded — a valid
    // document builds none. (Internal so the per-keyword validators in SchemaValidator+Keywords.swift
    // can render the same location for their diagnostics.)
    func location(_ path: [String]) -> String {
        path.isEmpty ? "" : "/" + path.joined(separator: "/")
    }

    // `depth` counts every recursive entry (schema-structural and instance-descent alike). Local
    // `$ref` cycles (a → b → a at one instance location) are broken via `activeRefs`; unbounded
    // *acyclic* depth is bounded by `maxValidationDepth`. The keyword groups live in
    // SchemaValidator+Keywords.swift; this dispatcher only fans out to them and ANDs their results.
    @discardableResult
    func validate(
        _ index: Int, _ instance: JSON, _ path: inout [String], _ errors: inout [ValidationError],
        _ ctx: ValidationContext = ValidationContext()
    ) -> Bool {
        guard ctx.depth <= maxValidationDepth else {
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

        // Each keyword group validates independently, ANDing its verdict into `ok` and appending any
        // errors; the recursive groups (array / object / applicators) thread `path` + `errors` and
        // re-enter `validate`. The numeric / string / type groups don't recurse, so they take `path`
        // by value (only for the error location).
        var ok = true
        if !validateRef(node, instance, &path, &errors, ctx) { ok = false }
        if !validateTypeConstEnum(node, instance, path, &errors) { ok = false }
        if !validateNumericBounds(node, instance, path, &errors) { ok = false }
        if !validateStringBounds(node, instance, path, &errors) { ok = false }
        if instance.isArray, !validateArray(node, instance, &path, &errors, ctx) { ok = false }
        if instance.isObject, !validateObject(node, instance, &path, &errors, ctx) { ok = false }
        if !validateApplicators(node, instance, &path, &errors, ctx) { ok = false }
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
