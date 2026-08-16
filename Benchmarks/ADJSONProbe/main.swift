import ADJSON
import AemiMetrics
import Foundation

// ADJSON vs Foundation, measured in-process with `AemiMetrics.ProcessProbe`: mean thread CPU and
// retired instructions per operation, plus the resident memory each parsed representation holds. The
// ordo-one suite reports per-benchmark percentiles; this puts ADJSON and Foundation side by side per
// operation and answers "how much memory does each representation cost". Markdown to stdout.
//
//   ADJSON_DEV=1 swift run -c release ADJSONProbe

// Keep a produced value "used" so the optimizer can't elide the work being measured.
@inline(never) func blackHole<T>(_ value: T) {}

// Mean per-op thread CPU (ns) and retired instructions over `iters` runs, after a short warmup.
func perOp(_ iters: Int, _ body: () -> Void) -> (cpu: UInt64, instr: UInt64) {
    for _ in 0 ..< 3 { body() }
    let (delta, _) = ProcessProbe.measure { () -> Int in
        for _ in 0 ..< iters { body() }
        return iters
    }
    let n = UInt64(iters)
    return (delta.threadCPUNanos / n, delta.instructions / n)
}

// Mean resident footprint one retained instance adds. Holds as many as fit a ~160 MB budget so the
// figure clears allocator page-cache noise (a single instance often reuses freed pages and reads 0).
// phys_footprint counts every allocation regardless of allocator, so it compares ADJSON and Foundation
// fairly. Approximate by nature (page-granular).
func heldFootprint<T>(_ build: () -> T) -> UInt64 {
    let budget: UInt64 = 160 << 20
    let before = ProcessProbe.footprintBytes()
    var held: [T] = []
    while held.count < 250 {
        held.append(build())
        if ProcessProbe.footprintBytes() &- before >= budget { break }
    }
    let after = ProcessProbe.footprintBytes()
    let n = UInt64(held.count)
    defer { withExtendedLifetime(held) {} }
    return n > 0 && after > before ? (after &- before) / n : 0
}

func ms(_ ns: UInt64) -> String { String(format: "%.2f", Double(ns) / 1_000_000) }
func instr(_ n: UInt64) -> String {
    if n >= 1_000_000 { return String(format: "%.0f M", Double(n) / 1e6) }
    if n >= 1_000 { return String(format: "%.0f K", Double(n) / 1e3) }
    return "\(n)"
}
func mem(_ b: UInt64) -> String {
    if b >= 1 << 20 { return String(format: "%.1f MB", Double(b) / Double(1 << 20)) }
    return String(format: "%.0f KB", Double(b) / 1024)
}
func ratio(_ foundation: UInt64, _ adjson: UInt64) -> String {
    adjson == 0 ? "—" : String(format: "%.1f×", Double(foundation) / Double(adjson))
}
func sourceMB(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / Double(1 << 20)) }

func corpusURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)  // Benchmarks/ADJSONProbe/main.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Benchmarks/Corpus/\(name)")
}

func speedRow(_ op: String, _ a: (cpu: UInt64, instr: UInt64), _ f: (cpu: UInt64, instr: UInt64)?) {
    let foundation = f.map { "\(ms($0.cpu)) ms · \(instr($0.instr))" } ?? "n/a"
    let speedup = f.map { ratio($0.cpu, a.cpu) } ?? "—"
    print("| \(op) | \(ms(a.cpu)) ms · \(instr(a.instr)) | \(foundation) | \(speedup) |")
}

func memRow(_ name: String, _ held: UInt64, vs foundation: UInt64) {
    print("| \(name) | \(mem(held)) | \(ratio(foundation, held)) smaller |")
}

let files: [(name: String, query: String)] = [
    ("twitter.json", "$.statuses[*].user.screen_name"),
    ("citm_catalog.json", "$..name"),
    ("canada.json", "$.features[*].geometry.type")
]

print("# ADJSON vs Foundation — measured with AemiMetrics.ProcessProbe (Apple Silicon, release)\n")

for file in files {
    guard let data = try? Data(contentsOf: corpusURL(file.name)) else {
        print("_skipped \(file.name) (run `swift package fetch-fixtures`)_\n")
        continue
    }
    let bytes = [UInt8](data)
    let iters = max(20, min(400, 30_000_000 / bytes.count))

    let document = try! ADJSON.parse(bytes)
    let value = JSONValue(document.root)
    let foundationObject = try! JSONSerialization.jsonObject(with: data)

    // Memory first, while the allocator is least churned. Each build returns a retained instance.
    let documentMemory = heldFootprint { try! ADJSON.parse(Array(data)) }
    let treeMemory = heldFootprint { JSONValue(document.root) }
    let foundationMemory = heldFootprint { try! JSONSerialization.jsonObject(with: data) }

    let lazyParse = perOp(iters) { blackHole(try! ADJSON.parse(bytes)) }
    let fullTree = perOp(iters) {
        let document = try! ADJSON.parse(bytes)
        blackHole(JSONValue(document.root))
    }
    let encode = perOp(iters) { blackHole(try! value.encodedBytes()) }
    let query = perOp(iters) { blackHole(try! document.root.query(file.query)) }
    let foundationParse = perOp(iters) { blackHole(try! JSONSerialization.jsonObject(with: data)) }
    let foundationEncode = perOp(iters) { blackHole(try! JSONSerialization.data(withJSONObject: foundationObject)) }

    print("### \(file.name) — \(sourceMB(bytes.count)) source · \(iters) iters/phase\n")
    print("**Speed** — thread CPU and retired instructions per op\n")
    print("| Operation | ADJSON | Foundation | ADJSON speedup |")
    print("|---|--:|--:|--:|")
    speedRow("Parse → lazy document", lazyParse, foundationParse)
    speedRow("Parse → full value tree", fullTree, foundationParse)
    speedRow("Encode value → bytes", encode, foundationEncode)
    speedRow("Query (lazy, pre-parsed)", query, nil)
    print("")
    print("**Memory** — resident footprint each parsed representation holds\n")
    print("| Representation | Held | vs Foundation |")
    print("|---|--:|--:|")
    memRow("ADJSON document (tape + source)", documentMemory, vs: foundationMemory)
    memRow("ADJSON value tree", treeMemory, vs: foundationMemory)
    print("| Foundation object graph | \(mem(foundationMemory)) | 1.0× |")
    print("")
}
