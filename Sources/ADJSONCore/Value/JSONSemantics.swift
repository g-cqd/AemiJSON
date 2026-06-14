// Core JSON value semantics shared by JSONPath comparisons and (in the umbrella) JSON
// Schema. Foundation-free; the schema-type mapping and pointer escaping stay in the
// Schema layer.

extension JSON {
    package var isNumberKind: Bool { tag == JSONKind.number.rawValue }
    package var isBoolKind: Bool { tag == JSONKind.boolTrue.rawValue || tag == JSONKind.boolFalse.rawValue }
    package var isStringKind: Bool { tag == JSONKind.string.rawValue }
}

/// Structural equality used by JSONPath comparisons and JSON Schema `const`/`enum`/`uniqueItems`.
/// Numerically, 1 and 1.0 compare equal (JSON value equality). Works across documents.
package func jsonSemanticEqual(_ a: JSON, _ b: JSON) -> Bool {
    // Iterative: a work-stack of pairs left to compare replaces structural recursion, so equality
    // of deeply nested values can't overflow the stack. Comparison order doesn't affect the result.
    var stack: [(JSON, JSON)] = [(a, b)]
    while let (x, y) = stack.popLast() {
        if x.isNull {
            if !y.isNull { return false }
        } else if let xb = x.bool {
            if y.bool != xb { return false }
        } else if x.isNumberKind {
            guard y.isNumberKind, let av = x.double, let bv = y.double, av == bv else { return false }
        } else if let xs = x.string {
            if y.string != xs { return false }
        } else if x.isArray {
            guard y.isArray, x.count == y.count, let xe = x.array, let ye = y.array else { return false }
            for i in 0..<xe.count { stack.append((xe[i], ye[i])) }
        } else if x.isObject {
            guard y.isObject, let xo = x.object, let yo = y.object, xo.count == yo.count else { return false }
            for (k, v) in xo {
                guard let yv = yo[k] else { return false }
                stack.append((v, yv))
            }
        } else {
            return false
        }
    }
    return true
}
