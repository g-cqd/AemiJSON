import ADJSON
import Foundation
import OrderedCollections

// MARK: - Bench harness

struct BenchResult {
    let name: String
    let bytes: Int
    let minNs: Double
    let medNs: Double
    var mbPerSec: Double { Double(bytes) * 1000.0 / medNs }
}

@inline(never) @_optimize(none)
func blackHole<T>(_ x: T) {}

extension Duration {
    var nanos: Double {
        let c = components
        return Double(c.seconds) * 1e9 + Double(c.attoseconds) / 1e9
    }
}

func bench(_ name: String, bytes: Int, iters: Int = 60, warmup: Int = 12, _ body: () -> Void) -> BenchResult {
    for _ in 0..<warmup { body() }
    let clk = ContinuousClock()
    var samples = [Double]()
    samples.reserveCapacity(iters)
    for _ in 0..<iters { samples.append(clk.measure(body).nanos) }
    samples.sort()
    return BenchResult(name: name, bytes: bytes, minNs: samples[0], medNs: samples[iters / 2])
}

func benchAsync(
    _ name: String, bytes: Int, iters: Int = 50, warmup: Int = 10, _ body: () async -> Void
) async -> BenchResult {
    for _ in 0..<warmup { await body() }
    let clk = ContinuousClock()
    var samples = [Double]()
    samples.reserveCapacity(iters)
    for _ in 0..<iters {
        let t0 = clk.now
        await body()
        samples.append((clk.now - t0).nanos)
    }
    samples.sort()
    return BenchResult(name: name, bytes: bytes, minNs: samples[0], medNs: samples[iters / 2])
}

func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
func padL(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }

func report(_ r: BenchResult, vs base: BenchResult?) {
    var line = pad(r.name, 34)
    line += padL(f1(r.medNs / 1000.0) + " us", 13)
    line += padL(f1(r.mbPerSec) + " MB/s", 15)
    if let b = base {
        let sp = b.medNs / r.medNs
        line += padL(f2(sp) + "x", 9)
        line += sp >= 1.0 ? "  faster" : "  slower"
    }
    print(line)
}

func section(_ title: String) { print("\n== \(title) ==") }

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    if buf.last == 0 { buf.removeLast() }
    return String(decoding: buf, as: UTF8.self)
}

// MARK: - Machine + payloads

let chip = sysctlString("machdep.cpu.brand_string") ?? "unknown CPU"
print("ADJSON benchmarks — \(chip), \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("Swift release build. Each row: median of 60 iters; MB/s = payload / median; xN vs baseline.")
print("Foundation coder/serialization instances are reused across iterations.\n")

let encoder = JSONEncoder()
let decoder = JSONDecoder()

let users = makeUsers(2000)
let userData = try! encoder.encode(users)
let usersDoc = try! ADJSON.parse(userData)
print("users payload  : \(userData.count) bytes, \(users.count) objects (nested, keyed-object-heavy)")

let doubles = makeDoubles(200_000)
let dData = try! encoder.encode(doubles)
print("doubles payload: \(dData.count) bytes, \(doubles.count) values (number-heavy)\n")

// MARK: - Correctness gates (no point timing a path that skips work)

let adUsers = try! ADJSON.JSONDecoder().decode([User].self, from: userData)
let macroUsers = try! ADJSON.JSONDecoder().decode([MacroUser].self, from: userData)
let adEncoded = try! ADJSON.JSONEncoder().encode(users)
let userArraySchema = try! JSONSchema(parsing: "{\"type\":\"array\",\"items\":\(MacroUser.__adjsonSchemaText)}")
print("verify decode  : ADJSON [User] == Foundation -> \(adUsers == users)")
print("verify macro   : ADJSON [MacroUser] count -> \(macroUsers.count == users.count)")
print("verify encode  : ADJSON round-trips -> \(try! decoder.decode([User].self, from: adEncoded) == users)")
print("verify schema  : @Schemable validates users -> \(userArraySchema.isValid(usersDoc.root))")

// Full lazy walk used by the untyped/corpus sections.
func adWalk(_ j: JSON) -> Int {
    if let o = j.object {
        var s = 0
        for (_, v) in o { s &+= adWalk(v) }
        return s
    }
    if let a = j.array {
        var s = 0
        for v in a { s &+= adWalk(v) }
        return s
    }
    if let i = j.int { return i }
    if let d = j.double { return Int(d) }
    if let str = j.string { return str.utf8.count }
    if let b = j.bool { return b ? 1 : 0 }
    return 0
}

// MARK: - Untyped parse (Data -> tree)

section("PARSE untyped  Data -> tree  (ADJSON vs Foundation JSONSerialization)")
let serBase = bench("Foundation JSONSerialization", bytes: userData.count) {
    blackHole(try! JSONSerialization.jsonObject(with: userData))
}
let tapeParse = bench("ADJSON parse (tape only)", bytes: userData.count) {
    blackHole(try! ADJSON.parse(userData))
}
let lazyTwo = bench("ADJSON parse + read 2 fields", bytes: userData.count) {
    let root = try! ADJSON.parse(userData).root
    var acc = 0
    for u in root.arrayValue {
        acc &+= u.id.intValue
        acc &+= u.login.stringValue.utf8.count
    }
    blackHole(acc)
}
let fullWalk = bench("ADJSON parse + full walk", bytes: userData.count) {
    blackHole(adWalk(try! ADJSON.parse(userData).root))
}
let valueTree = bench("ADJSON JSONValue (full tree)", bytes: userData.count) {
    blackHole(try! JSONValue(parsing: userData))
}
report(serBase, vs: nil)
report(tapeParse, vs: serBase)
report(lazyTwo, vs: serBase)
report(fullWalk, vs: serBase)
report(valueTree, vs: serBase)

// Whitespace-heavy parse (exercises the SWAR `skipWS`): the same users payload re-serialized
// pretty-printed, so insignificant whitespace dominates the inter-token gaps.
let prettyEncoder = JSONEncoder()
prettyEncoder.outputFormatting = [.prettyPrinted]
let usersPretty = try! prettyEncoder.encode(users)
print("ws-heavy payload: \(usersPretty.count) bytes (pretty-printed users)")
let wsFound = bench("Foundation JSONSerialization (ws)", bytes: usersPretty.count) {
    blackHole(try! JSONSerialization.jsonObject(with: usersPretty))
}
let wsParse = bench("ADJSON parse (ws-heavy)", bytes: usersPretty.count) {
    blackHole(try! ADJSON.parse(usersPretty))
}
report(wsFound, vs: nil)
report(wsParse, vs: wsFound)

// Non-ASCII-heavy parse (exercises strict UTF-8 continuation validation in `scanString`): an array
// of CJK strings, so multi-byte sequences dominate the string bytes.
let cjkStrings = (0..<4000).map { _ in "日本語のテキストデータ、これはベンチマーク用の文字列です。" }
let cjkData = try! encoder.encode(cjkStrings)
print("cjk payload    : \(cjkData.count) bytes (\(cjkStrings.count) CJK strings)")
let cjkFound = bench("Foundation JSONSerialization (cjk)", bytes: cjkData.count) {
    blackHole(try! JSONSerialization.jsonObject(with: cjkData))
}
let cjkParse = bench("ADJSON parse (cjk, strict UTF-8)", bytes: cjkData.count) {
    blackHole(try! ADJSON.parse(cjkData))
}
report(cjkFound, vs: nil)
report(cjkParse, vs: cjkFound)

// MARK: - Typed decode (Data -> [User])

section("DECODE typed  Data -> [User]  (ADJSON vs Foundation JSONDecoder)")
let fDec = bench("Foundation JSONDecoder", bytes: userData.count) {
    blackHole(try! decoder.decode([User].self, from: userData))
}
let adGenericDec = ADJSON.JSONDecoder()
let adDec = bench("ADJSON JSONDecoder (Codable)", bytes: userData.count) {
    blackHole(try! adGenericDec.decode([User].self, from: userData))
}
let adMacroDecoder = ADJSON.JSONDecoder()
let adMacroDec = bench("ADJSON @JSONCodable (fast path)", bytes: userData.count) {
    blackHole(try! adMacroDecoder.decode([MacroUser].self, from: userData))
}
report(fDec, vs: nil)
report(adDec, vs: fDec)
report(adMacroDec, vs: fDec)

// MARK: - Typed encode ([User] -> Data)

section("ENCODE typed  [User] -> Data  (ADJSON vs Foundation JSONEncoder)")
let fEnc = bench("Foundation JSONEncoder", bytes: userData.count) {
    blackHole(try! encoder.encode(users))
}
let adGenericEnc = ADJSON.JSONEncoder()
let adEnc = bench("ADJSON JSONEncoder (Codable)", bytes: userData.count) {
    blackHole(try! adGenericEnc.encode(users))
}
let adMacroEncoder = ADJSON.JSONEncoder()
let adMacroEnc = bench("ADJSON @JSONCodable (fast path)", bytes: userData.count) {
    blackHole(try! adMacroEncoder.encode(macroUsers))
}
report(fEnc, vs: nil)
report(adEnc, vs: fEnc)
report(adMacroEnc, vs: fEnc)

// JSONValue model serialization (the hybrid recursive/iterative `write`), independent of Codable:
// materialize the users tree once, then time `encodedBytes()` over it.
let usersValueForEncode = try! JSONValue(parsing: userData)
let valueEnc = bench("ADJSON JSONValue.encodedBytes", bytes: userData.count) {
    blackHole(try! usersValueForEncode.encodedBytes())
}
report(valueEnc, vs: fEnc)

// MARK: - Number-heavy decode ([Double])

section("DECODE [Double]  number-heavy  (ADJSON vs Foundation JSONDecoder)")
let fDoubles = bench("Foundation JSONDecoder", bytes: dData.count) {
    blackHole(try! decoder.decode([Double].self, from: dData))
}
let adDoublesDecoder = ADJSON.JSONDecoder()
let adDoubles = bench("ADJSON JSONDecoder", bytes: dData.count) {
    blackHole(try! adDoublesDecoder.decode([Double].self, from: dData))
}
report(fDoubles, vs: nil)
report(adDoubles, vs: fDoubles)

// Isolated number parsing (no Codable container overhead): parse + read every value through the
// lazy `.double` accessor. This is the Eisel-Lemire hot path — `JSONNumber.parseDouble`.
let adNumWalk = bench("ADJSON parse + sum doubles (lazy)", bytes: dData.count) {
    let root = try! ADJSON.parse(dData).root
    var s = 0.0
    root.forEachElement { s += $0.doubleValue }
    blackHole(s)
}
report(adNumWalk, vs: fDoubles)

// MARK: - Query (JSONPath, RFC 9535) — pre-parsed root, no Foundation equivalent

section("QUERY  JSONPath over pre-parsed [User]  (ADJSON only)")
let pathFilter = "$[?(@.followers > 50000)].login"
let pathWildcard = "$[*].profile.bio"
let filterHits = (try? usersDoc.root.query(pathFilter))?.count ?? -1
let wildcardHits = (try? usersDoc.root.query(pathWildcard))?.count ?? -1
print("verify query   : \(pathFilter) -> \(filterHits) hits; \(pathWildcard) -> \(wildcardHits) hits")
let queryFilter = bench("filter  \(pathFilter)", bytes: userData.count) {
    blackHole((try? usersDoc.root.query(pathFilter)) ?? [])
}
let queryWildcard = bench("wildcard  \(pathWildcard)", bytes: userData.count) {
    blackHole((try? usersDoc.root.query(pathWildcard)) ?? [])
}
report(queryFilter, vs: nil)
report(queryWildcard, vs: nil)

// Filter with an absolute (`$`-rooted) sub-query: `$[0].followers` is candidate-independent, so the
// sub-query cache evaluates it once instead of once per of the 2000 candidates.
let pathAbsFilter = "$[?(@.followers > $[0].followers)]"
let absFilterHits = (try? usersDoc.root.query(pathAbsFilter))?.count ?? -1
print("verify abs-filt: \(pathAbsFilter) -> \(absFilterHits) hits")
let queryAbsFilter = bench("filter abs-subquery", bytes: userData.count) {
    blackHole((try? usersDoc.root.query(pathAbsFilter)) ?? [])
}
report(queryAbsFilter, vs: nil)

// JSONPath compilation (string -> AST). Exercises the path parser itself (the byte-vs-`[Character]`
// target), independent of evaluation; each iteration compiles the set 1000x for stable timing.
section("COMPILE  JSONPath string -> AST  (ADJSON only)")
let pathStrings = [
    "$.store.book[*].title",
    #"$[?(@.followers > 50000 && @.login != "abc")].login"#,
    "$..profile.bio",
    "$['a']['b'][0:10:2].c",
]
let pathSrcBytes = pathStrings.reduce(0) { $0 + $1.utf8.count } * 1000
let pathCompile = bench("compile 4 paths x1000", bytes: pathSrcBytes, iters: 200, warmup: 40) {
    for _ in 0..<1000 { for p in pathStrings { blackHole(try? JSONPath(p)) } }
}
report(pathCompile, vs: nil)

// MARK: - Schema validation (Draft 2020-12 subset) — compile once, validate many

section("VALIDATE  JSON Schema over pre-parsed [User]  (ADJSON only)")
let schemaValidate = bench("JSONSchema.validate (pre-parsed)", bytes: userData.count) {
    blackHole(userArraySchema.isValid(usersDoc.root))
}
let schemaParseValidate = bench("parse + validate", bytes: userData.count) {
    blackHole(userArraySchema.isValid(try! ADJSON.parse(userData).root))
}
report(schemaValidate, vs: nil)
report(schemaParseValidate, vs: nil)

// MARK: - Mutation (JSON Patch, RFC 6902) — apply to a materialized tree

section("MUTATE  JSON Patch apply over [User] tree  (ADJSON only)")
let patchJSON = #"""
    [{"op":"replace","path":"/0/login","value":"patched"},
     {"op":"add","path":"/0/flagged","value":true},
     {"op":"remove","path":"/1/following"}]
    """#
let patch = try! JSONPatch(Data(patchJSON.utf8))
let usersValue = try! JSONValue(parsing: userData)
blackHole(try! patch.apply(to: usersValue))
let patchApply = bench("JSONPatch.apply (3 ops)", bytes: userData.count) {
    blackHole(try! patch.apply(to: usersValue))
}
report(patchApply, vs: nil)

// MARK: - Concurrent decode (off the main actor, across cores)

section("CONCURRENT decode [User] from a pre-parsed document  (ADJSON)")
let serialDec = bench("serial decode", bytes: userData.count) {
    blackHole(try! ADJSON.JSONDecoder().decode([User].self, from: usersDoc))
}
let concDec = await benchAsync("concurrent decode", bytes: userData.count) {
    blackHole(try! await ADJSON.decodeArrayConcurrently(User.self, from: usersDoc, minimumBatch: 256))
}
report(serialDec, vs: nil)
report(concDec, vs: serialDec)

// MARK: - Standard corpus (untyped) vs Foundation JSONSerialization

func corpusURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Sources/ADJSONBenchmarks
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Benchmarks/Corpus/\(name)")
}

section("CORPUS untyped  (ADJSON vs Foundation JSONSerialization)")
var corpusGatePassed = true
for file in ["twitter.json", "citm_catalog.json", "canada.json"] {
    guard let data = try? Data(contentsOf: corpusURL(file)) else {
        print("  (skip \(file): not found — run `swift package ... fetch-fixtures`)")
        continue
    }
    print("-- \(file) (\(data.count) bytes) --")
    let fs = bench("Foundation JSONSerialization", bytes: data.count) {
        blackHole(try! JSONSerialization.jsonObject(with: data))
    }
    let parse = bench("ADJSON parse (tape)", bytes: data.count) { blackHole(try! ADJSON.parse(data)) }
    let walk = bench("ADJSON parse + full walk", bytes: data.count) { blackHole(adWalk(try! ADJSON.parse(data).root)) }
    let value = bench("ADJSON JSONValue (full tree)", bytes: data.count) { blackHole(try! JSONValue(parsing: data)) }
    report(fs, vs: nil)
    report(parse, vs: fs)
    report(walk, vs: fs)
    report(value, vs: fs)
    if parse.medNs > fs.medNs {
        corpusGatePassed = false
        print("  REGRESSION: ADJSON parse slower than JSONSerialization on \(file)")
    }
}
print(corpusGatePassed ? "corpus gate: PASS" : "corpus gate: FAIL")

// MARK: - Eager-object backing: Dictionary vs OrderedDictionary (the G2 adoption rationale)

section("OBJECT MODEL  Dictionary vs OrderedDictionary  (eager JSONValue.object backing)")
// Representative small object: the ~10 string keys of the User/Profile shape, built and fully
// looked up many times (the JSONValue.object materialization + member-access pattern). This is why
// JSONValue.object is an OrderedDictionary — faster for small objects *and* order-preserving.
let objKeys = [
    "id", "login", "name", "email", "followers", "following", "isAdmin", "score", "tags", "profile",
]
let objReps = 200_000
let objBytes = objReps * objKeys.reduce(0) { $0 + $1.utf8.count }

let dictBuild = bench("Dictionary build+lookup x10", bytes: objBytes) {
    var sink = 0
    for _ in 0..<objReps {
        var d = [String: Int](minimumCapacity: objKeys.count)
        for (i, k) in objKeys.enumerated() { d[k] = i }
        for k in objKeys { sink &+= d[k] ?? 0 }
    }
    blackHole(sink)
}
let orderedBuild = bench("OrderedDictionary build+lookup x10", bytes: objBytes) {
    var sink = 0
    for _ in 0..<objReps {
        var d = OrderedDictionary<String, Int>(minimumCapacity: objKeys.count)
        for (i, k) in objKeys.enumerated() { d[k] = i }
        for k in objKeys { sink &+= d[k] ?? 0 }
    }
    blackHole(sink)
}
report(dictBuild, vs: nil)
report(orderedBuild, vs: dictBuild)

var ordered = OrderedDictionary<String, Int>()
for (i, k) in objKeys.enumerated() { ordered[k] = i }
let plain = Dictionary(uniqueKeysWithValues: objKeys.enumerated().map { ($1, $0) })
print("advantage      : OrderedDictionary preserves insertion order -> \(Array(ordered.keys) == objKeys)")
print("                 plain Dictionary preserves it -> \(Array(plain.keys) == objKeys) (order is unspecified)")

let metrics = ADJSON.Metrics.snapshot()
print("\nSynchronization metrics: documents=\(metrics.documents) bytes=\(metrics.bytes)")
