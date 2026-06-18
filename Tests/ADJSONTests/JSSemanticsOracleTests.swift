#if canImport(JavaScriptCore)
    import Foundation
    import JavaScriptCore
    import Testing

    @testable import ADJSON

    // Validate the JS-semantics accessors against JavaScriptCore — WebKit's production JavaScript
    // engine — which is the authoritative oracle for ECMAScript coercion. Apple-platforms only (there
    // is no JavaScriptCore on Linux); the engine-independent algorithm tests in
    // `ZeroCopyAccessorsTests` run everywhere, so coverage degrades gracefully.
    //
    // `jsString` implements `Array.prototype.join`'s *element* coercion (so `null`/`undefined` → "",
    // not the `"null"`/`"undefined"` of standalone `String(x)`), because that is the content-pipeline
    // contract. The oracle therefore compares against `[x].join("")`, the exact JS operation that
    // coercion mirrors — `Boolean(x)` and `String(n)` are spec-exact for the other two.

    /// A fresh JavaScriptCore context with the three coercion oracles. Not `Sendable` (JSValue is a
    /// reference into the VM), so each test makes its own and uses it synchronously.
    private final class JSOracle {
        let ctx: JSContext
        private let truthyFn: JSValue
        private let truthyRootFn: JSValue
        private let coerceFn: JSValue
        private let coerceRootFn: JSValue
        private let numFn: JSValue

        init() {
            let ctx = JSContext()!
            self.ctx = ctx
            truthyFn = ctx.evaluateScript("(function(t,k){ return Boolean(JSON.parse(t)[k]); })")
            truthyRootFn = ctx.evaluateScript("(function(t){ return Boolean(JSON.parse(t)); })")
            coerceFn = ctx.evaluateScript("(function(t,k){ return [JSON.parse(t)[k]].join(''); })")
            coerceRootFn = ctx.evaluateScript("(function(t){ return [JSON.parse(t)].join(''); })")
            numFn = ctx.evaluateScript("(function(n){ return String(n); })")
        }

        func truthy(_ text: String, key: String) -> Bool { truthyFn.call(withArguments: [text, key]).toBool() }
        func truthyRoot(_ text: String) -> Bool { truthyRootFn.call(withArguments: [text]).toBool() }
        func coerce(_ text: String, key: String) -> String { coerceFn.call(withArguments: [text, key]).toString() }
        func coerceRoot(_ text: String) -> String { coerceRootFn.call(withArguments: [text]).toString() }
        func numberString(_ d: Double) -> String {
            numFn.call(withArguments: [JSValue(double: d, in: ctx)!]).toString()
        }
    }

    // Object whose members exercise every coercion branch; each value is checked key-by-key against JS.
    private let semanticsFixture = #"""
        {"t":true,"f":false,"nul":null,"zero":0,"negzero":-0.0,"one":1,"negone":-1,
         "big":1e21,"small":1e-7,"pi":3.14,"empty":"","s":"hello","strzero":"0",
         "strfalse":"false","space":" ","arr":[],"arr1":[1,2,3],"mixed":[1,null,"x",true],
         "nested":[1,[2,3],4],"obj":{},"obj1":{"k":1},"arrobj":[{"a":1},2]}
        """#

    @Test func isTruthyMatchesJavaScriptCorePerMember() throws {
        let oracle = JSOracle()
        let root = try ADJSON.parse(semanticsFixture).root
        root.forEachMember { key, value in
            #expect(value.isTruthy == oracle.truthy(semanticsFixture, key: key), "isTruthy mismatch at \(key)")
        }
        // Absent member → JS `undefined` → falsy.
        #expect(root.does_not_exist.isTruthy == oracle.truthy(semanticsFixture, key: "does_not_exist"))
    }

    @Test func jsStringMatchesJavaScriptCorePerMember() throws {
        let oracle = JSOracle()
        let root = try ADJSON.parse(semanticsFixture).root
        root.forEachMember { key, value in
            #expect(value.jsString == oracle.coerce(semanticsFixture, key: key), "jsString mismatch at \(key)")
        }
        #expect(root.does_not_exist.jsString == oracle.coerce(semanticsFixture, key: "does_not_exist"))
    }

    @Test func jsStringAndTruthyMatchJavaScriptCoreForRootValues() throws {
        let oracle = JSOracle()
        let texts = [
            "null", "true", "false", "0", "1", "3.14", "1e21", #""hi""#, #""""#,
            "[]", "[1,2,3]", "[null,1,null]", "[[],1]", "[1,[2,3],4]", "[[1,2],[3,4]]",
            "[[1,[2]],3]", "{}", #"{"a":1}"#, #"[{"a":1},2]"#
        ]
        for text in texts {
            let root = try ADJSON.parse(text).root
            #expect(root.jsString == oracle.coerceRoot(text), "jsString root mismatch: \(text)")
            #expect(root.isTruthy == oracle.truthyRoot(text), "isTruthy root mismatch: \(text)")
        }
    }

    @Test func ecmaNumberToStringMatchesJavaScriptCore() {
        let oracle = JSOracle()
        let known: [Double] = [
            0, -0.0, 1, -1, 5, 100, 1_000_000, 3.14, 0.1, 0.5, -0.25, 1234.5678, 123_456_789,
            9_007_199_254_740_992, 1e21, 1e-7, 1e-6, 0.000001, 1.5e300, -1.5e-300,
            1.7976931348623157e308, 5e-324, 2.2250738585072014e-308, 123_456_789_012_345_680,
            .nan, .infinity, -.infinity
        ]
        for d in known {
            #expect(JSONOutput.ecmaNumberToString(d) == oracle.numberString(d), "ecma(\(d))")
        }
        // Randomized fuzz against the engine: every finite double must format identically to V8/JSC.
        var rng = SystemRandomNumberGenerator()
        for _ in 0 ..< 5_000 {
            let d = Double(bitPattern: UInt64.random(in: 0 ... UInt64.max, using: &rng))
            guard d.isFinite else { continue }
            #expect(JSONOutput.ecmaNumberToString(d) == oracle.numberString(d), "ecma(\(d))")
        }
    }

    @Test func jsNumberStringMatchesJavaScriptCore() throws {
        let oracle = JSOracle()
        let root = try ADJSON.parse(#"{"i":42,"d":2.5,"big":1e21,"tiny":1e-7,"neg":-0.0}"#).root
        for key in ["i", "d", "big", "tiny", "neg"] {
            let d = root[key].doubleValue
            #expect(root[key].jsNumberString == oracle.numberString(d), "jsNumberString at \(key)")
        }
    }
#endif
