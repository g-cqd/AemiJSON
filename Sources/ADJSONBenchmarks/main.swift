import ADJSON
import Foundation

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
    var line = pad(r.name, 30)
    line += padL(f1(r.medNs / 1000.0) + " us", 14)
    line += padL(f1(r.mbPerSec) + " MB/s", 16)
    if let b = base {
        let sp = b.medNs / r.medNs
        line += padL(f2(sp) + "x", 10)
        line += sp >= 1.0 ? "  (faster)" : "  (slower)"
    }
    print(line)
}

// MARK: - Setup

print("ADJSON spike — Apple M2 Pro, \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("Swift release build. Foundation instances reused across iterations.\n")

let users = makeUsers(2000)
let encoder = JSONEncoder()
let decoder = JSONDecoder()
let userData = try! encoder.encode(users)
print("users payload : \(userData.count) bytes, \(users.count) objects")

// Correctness gates (no point benchmarking a parser that skips work)
let miniUsers: [User] = userData.withUnsafeBytes { raw in
    var prs = JSONByteParser(raw.bindMemory(to: UInt8.self).baseAddress!, raw.count)
    return prs.parseUsers()
}
let fUsers = try! decoder.decode([User].self, from: userData)
print("verify decode : mini == foundation -> \(miniUsers == fUsers && fUsers == users)")

let miniEncoded = MiniEncoder.encode(users)
let reDecoded = try! decoder.decode([User].self, from: Data(miniEncoded))
print("verify encode : mini round-trips    -> \(reDecoded == users)  (\(miniEncoded.count) bytes)\n")

// MARK: - Decode (typed)

print("== DECODE typed  Data -> [User]  (keyed-object-heavy) ==")
let fd = bench("Foundation JSONDecoder", bytes: userData.count) {
    blackHole(try! decoder.decode([User].self, from: userData))
}
let md = bench("Mini targeted decoder", bytes: userData.count) {
    userData.withUnsafeBytes { raw in
        var prs = JSONByteParser(raw.bindMemory(to: UInt8.self).baseAddress!, raw.count)
        blackHole(prs.parseUsers())
    }
}
report(fd, vs: nil)
report(md, vs: fd)

let adDecoder = ADJSON.JSONDecoder()
let adUsers = try! adDecoder.decode([User].self, from: userData)
print("verify       : ADJSON.JSONDecoder == foundation -> \(adUsers == fUsers)")
let add = bench("ADJSON.JSONDecoder (Codable)", bytes: userData.count) {
    blackHole(try! adDecoder.decode([User].self, from: userData))
}
report(add, vs: fd)

// MARK: - Parse (untyped)

print("\n== PARSE untyped  Data -> tree ==")
let fs = bench("Foundation JSONSerialization", bytes: userData.count) {
    blackHole(try! JSONSerialization.jsonObject(with: userData))
}
let ms = bench("Mini JSONValue parser", bytes: userData.count) {
    userData.withUnsafeBytes { raw in
        var prs = JSONByteParser(raw.bindMemory(to: UInt8.self).baseAddress!, raw.count)
        blackHole(prs.parseValue())
    }
}
report(fs, vs: nil)
report(ms, vs: fs)

// MARK: - ADJSON untyped (tape + lazy materialization)

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

print("\n== ADJSON untyped  (tape + lazy) ==")
let adParse = bench("ADJSON parse (tape only)", bytes: userData.count) {
    blackHole(try! ADJSON.parse(userData))
}
let adLazy = bench("ADJSON parse + read 2 fields", bytes: userData.count) {
    let root = try! ADJSON.parse(userData).root
    var acc = 0
    for u in root.arrayValue {
        acc &+= u.id.intValue
        acc &+= u.login.stringValue.utf8.count
    }
    blackHole(acc)
}
let adFull = bench("ADJSON parse + full walk", bytes: userData.count) {
    blackHole(adWalk(try! ADJSON.parse(userData).root))
}
report(fs, vs: nil)
report(adParse, vs: fs)
report(adLazy, vs: fs)
report(adFull, vs: fs)

// MARK: - Encode (typed)

print("\n== ENCODE typed  [User] -> Data ==")
let fe = bench("Foundation JSONEncoder", bytes: userData.count) {
    blackHole(try! encoder.encode(users))
}
let me_ = bench("Mini direct encoder", bytes: userData.count) {
    blackHole(MiniEncoder.encode(users))
}
report(fe, vs: nil)
report(me_, vs: fe)

let adEncoder = ADJSON.JSONEncoder()
let adEncoded = try! adEncoder.encode(users)
print(
    "verify       : ADJSON.JSONEncoder round-trips -> \(try! JSONDecoder().decode([User].self, from: adEncoded) == users)"
)
let ade = bench("ADJSON.JSONEncoder (Codable)", bytes: userData.count) {
    blackHole(try! adEncoder.encode(users))
}
report(ade, vs: fe)

let anyObj = try! JSONSerialization.jsonObject(with: userData)
let fser = bench("Foundation JSONSerialization data", bytes: userData.count) {
    blackHole(try! JSONSerialization.data(withJSONObject: anyObj))
}
report(fser, vs: nil)

// MARK: - Number-heavy (hard case for us)

print("\n== DECODE [Double]  (number-heavy, HARD case) ==")
let doubles = makeDoubles(200_000)
let dData = try! encoder.encode(doubles)
print("doubles payload: \(dData.count) bytes")
let miniDoubles: [Double] = dData.withUnsafeBytes { raw in
    var prs = JSONByteParser(raw.bindMemory(to: UInt8.self).baseAddress!, raw.count)
    return prs.parseDoubleArray()
}
print("verify decode : mini == foundation -> \(miniDoubles == doubles)")
let fdd = bench("Foundation JSONDecoder", bytes: dData.count) {
    blackHole(try! decoder.decode([Double].self, from: dData))
}
let mdd = bench("Mini double-array parser", bytes: dData.count) {
    dData.withUnsafeBytes { raw in
        var prs = JSONByteParser(raw.bindMemory(to: UInt8.self).baseAddress!, raw.count)
        blackHole(prs.parseDoubleArray())
    }
}
report(fdd, vs: nil)
report(mdd, vs: fdd)

print("\n== RAW STRUCTURAL SCAN (ceiling for a lazy tape-backed untyped value) ==")
var tapeU = [Int32]()
tapeU.reserveCapacity(userData.count / 2)
let scU = bench("SWAR scan (users)", bytes: userData.count) {
    userData.withUnsafeBytes { raw in scanScalar(raw.bindMemory(to: UInt8.self).baseAddress!, raw.count, &tapeU) }
}
let scSU = bench("SIMD16 scan (users)", bytes: userData.count) {
    userData.withUnsafeBytes { raw in scanSIMD(raw.bindMemory(to: UInt8.self).baseAddress!, raw.count, &tapeU) }
}
report(scU, vs: nil)
report(scSU, vs: scU)
blackHole(tapeU.count)

var tapeD = [Int32]()
tapeD.reserveCapacity(dData.count / 4)
let scD = bench("SWAR scan (doubles)", bytes: dData.count) {
    dData.withUnsafeBytes { raw in scanScalar(raw.bindMemory(to: UInt8.self).baseAddress!, raw.count, &tapeD) }
}
let scSD = bench("SIMD16 scan (doubles)", bytes: dData.count) {
    dData.withUnsafeBytes { raw in scanSIMD(raw.bindMemory(to: UInt8.self).baseAddress!, raw.count, &tapeD) }
}
report(scD, vs: nil)
report(scSD, vs: scD)
blackHole(tapeD.count)

print("\n== CONCURRENT decode [User] (pre-parsed, off main actor) ==")
let docConc = try! ADJSON.parse(userData)
let adDec3 = ADJSON.JSONDecoder()
let serialDec = bench("serial decode", bytes: userData.count) {
    blackHole(try! adDec3.decode([User].self, from: docConc))
}
let concDec = await benchAsync("concurrent decode", bytes: userData.count) {
    blackHole(try! await ADJSON.decodeArrayConcurrently(User.self, from: docConc, minimumBatch: 256))
}
report(serialDec, vs: nil)
report(concDec, vs: serialDec)
let metrics = ADJSONMetrics.snapshot()
print("Synchronization metrics: documents=\(metrics.documents) bytes=\(metrics.bytes)")

// MARK: - Standard corpus (untyped) vs Foundation JSONSerialization

func corpusURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Sources/ADJSONBenchmarks
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Benchmarks/Corpus/\(name)")
}

print("\n== CORPUS untyped  (ADJSON vs Foundation JSONSerialization) ==")
var corpusGatePassed = true
for file in ["twitter.json", "citm_catalog.json", "canada.json"] {
    guard let data = try? Data(contentsOf: corpusURL(file)) else {
        print("  (skip \(file): not found)")
        continue
    }
    let bytes = data.count
    print("-- \(file) (\(bytes) bytes) --")
    let fs = bench("Foundation JSONSerialization", bytes: bytes) {
        blackHole(try! JSONSerialization.jsonObject(with: data))
    }
    let parse = bench("ADJSON parse (tape)", bytes: bytes) { blackHole(try! ADJSON.parse(data)) }
    let walk = bench("ADJSON parse + full walk", bytes: bytes) { blackHole(adWalk(try! ADJSON.parse(data).root)) }
    report(fs, vs: nil)
    report(parse, vs: fs)
    report(walk, vs: fs)
    if parse.medNs > fs.medNs {
        corpusGatePassed = false
        print("  REGRESSION: ADJSON parse slower than JSONSerialization on \(file)")
    }
}
print(corpusGatePassed ? "corpus gate: PASS" : "corpus gate: FAIL")

print("\n== @JSONCodable macro  (decode/encode [MacroUser]) ==")
let macroDecoder = ADJSON.JSONDecoder()
let macroEncoder = ADJSON.JSONEncoder()
let macroUsers = try! macroDecoder.decode([MacroUser].self, from: userData)
print("verify       : @JSONCodable decoded \(macroUsers.count) users")
let macroDec = bench("@JSONCodable decode", bytes: userData.count) {
    blackHole(try! macroDecoder.decode([MacroUser].self, from: userData))
}
let macroEnc = bench("@JSONCodable encode", bytes: userData.count) {
    blackHole(try! macroEncoder.encode(macroUsers))
}
report(fd, vs: nil)
report(macroDec, vs: fd)
report(fe, vs: nil)
report(macroEnc, vs: fe)

print("\n(min times, for reference)")
print(pad("decode users", 26) + "F " + f1(fd.minNs / 1000) + "us  M " + f1(md.minNs / 1000) + "us")
print(pad("encode users", 26) + "F " + f1(fe.minNs / 1000) + "us  M " + f1(me_.minNs / 1000) + "us")
