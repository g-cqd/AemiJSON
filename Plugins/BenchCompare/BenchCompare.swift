import Foundation
import PackagePlugin

/// `swift package bench-compare [--filter REGEX] [--input FILE] [--config release] [--bin-path PATH]`
/// — render the ADJSON-vs-Foundation comparison table (Markdown) from the standalone "Debug results"
/// output of the `ADJSONSuite` benchmark binary (ordo-one/benchmark). Replaces the shell + awk pair
/// `Scripts/bench-compare.{sh,awk}` with one Swift plugin.
///
/// It reuses an already-built suite binary (the benchmark CI step builds it; locally run
/// `ADJSON_DEV=1 swift build -c release --product ADJSONSuite` first) rather than building — so it
/// never nests a `swift build` inside the plugin invocation. `--input FILE` re-renders a previously
/// captured run without executing anything. Only the Markdown table goes to stdout, so it pipes
/// cleanly into a CI job summary.
@main
struct BenchComparePlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var filter: String?
        var inputFile: String?
        var binPathOverride: String?
        var config = "release"
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--filter": filter = iterator.next()
            case "--input": inputFile = iterator.next()
            case "--bin-path": binPathOverride = iterator.next()
            case "--config": if let value = iterator.next() { config = value }
            default: break
            }
        }

        let rawOutput: String
        if let inputFile {
            rawOutput = try String(contentsOfFile: inputFile, encoding: .utf8)
        } else {
            let binDir =
                binPathOverride.map { URL(fileURLWithPath: $0) }
                ?? context.package.directoryURL.appending(path: ".build/\(config)")
            let binary = binDir.appending(path: "ADJSONSuite")
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                Diagnostics.error(
                    "no ADJSONSuite binary at \(binary.path); build it first: "
                        + "ADJSON_DEV=1 swift build -c \(config) --product ADJSONSuite")
                throw BenchCompareError.noBinary
            }
            var runArguments = ["--quiet", "true"]
            if let filter { runArguments += ["--filter", filter] }
            rawOutput = try runCapturing(binary.path, runArguments)
        }

        print(BenchComparison.render(rawOutput: rawOutput))
    }

    /// Run a tool and return its standard output. Drains the pipe before waiting so a large run can't
    /// deadlock on a full pipe buffer.
    private func runCapturing(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

enum BenchCompareError: Error {
    case noBinary
}

/// Parses the suite's "Debug results" sections and renders the comparison table. The suite names
/// benchmarks `<workload>/<variant>` and registers the Foundation baseline first in each workload; the
/// `corpus` workload prefixes the variant with the file name (`corpus/twitter Foundation`), so each
/// file is its own group. Every ADJSON variant is paired with the Foundation baseline in its group;
/// the speedup is `Foundation ÷ ADJSON` (>1 means ADJSON is faster). p50 wall-clock is printed in
/// nanoseconds by the runner in standalone debug mode, so it is divided by 1e6 for milliseconds.
enum BenchComparison {
    static func render(rawOutput: String) -> String {
        var order: [String] = []
        var seen = Set<String>()
        var p50: [String: Double] = [:]
        var mallocTotal: [String: Double] = [:]
        var name = ""
        var section = ""  // "time" | "thru" | "mal" | ""

        for rawLine in rawOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("Debug results for ") {
                var parsed = line
                parsed.removeFirst("Debug results for ".count)
                if parsed.hasSuffix(":") { parsed.removeLast() }
                name = parsed
                section = ""
                if seen.insert(parsed).inserted { order.append(parsed) }
                continue
            }
            if line.hasPrefix("Time (wall clock):") {
                section = "time"
                continue
            }
            if line.hasPrefix("Throughput") {
                section = "thru"
                continue
            }
            if line.hasPrefix("Malloc") {
                section = "mal"
                continue
            }
            // Histogram p50 row in the wall-clock section: "<value> 0.500000000000 <count> <ratio>".
            if section == "time", p50[name] == nil {
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if fields.count >= 2, fields[1] == "0.500000000000" {
                    p50[name] = Double(fields[0]) ?? 0
                    continue
                }
            }
            // Per-section mean line; only the malloc total is needed (timings use the p50 above).
            if line.hasPrefix("#[Mean"), section == "mal" {
                mallocTotal[name] = number(after: line)
            }
        }

        if order.isEmpty { return "_No benchmark results parsed._" }

        var workload: [String: String] = [:]
        var variant: [String: String] = [:]
        var baseline: [String: String] = [:]
        for entry in order {
            guard let slash = entry.firstIndex(of: "/") else { continue }
            let category = String(entry[entry.startIndex..<slash])
            let remainder = String(entry[entry.index(after: slash)...])
            let group: String
            let label: String
            if category == "corpus", let gap = remainder.firstIndex(of: " ") {
                group = category + "/" + String(remainder[remainder.startIndex..<gap])
                label = String(remainder[remainder.index(after: gap)...])
            } else {
                group = category
                label = remainder
            }
            workload[entry] = group
            variant[entry] = label
            if label.contains("Foundation") { baseline[group] = entry }
        }

        var lines = [
            "| Workload | Foundation | ADJSON | p50 (F) | p50 (A) | Speedup | Mallocs (F→A) |",
            "|---|---|---|--:|--:|--:|--:|",
        ]
        var rows = 0
        for entry in order {
            guard let group = workload[entry], let base = baseline[group], base != entry else { continue }
            let basePoint = p50[base] ?? 0
            let entryPoint = p50[entry] ?? 0
            let ratio = entryPoint == 0 ? 0 : basePoint / entryPoint
            lines.append(
                "| `\(group)` | \(variant[base] ?? "") | \(variant[entry] ?? "") | \(ms(basePoint)) ms "
                    + "| \(ms(entryPoint)) ms | \(speed(ratio)) | \(mallocs(mallocTotal[base] ?? 0, mallocTotal[entry] ?? 0)) |"
            )
            rows += 1
        }

        lines.append("")
        lines.append(
            "_\(rows) comparisons · p50 wall-clock · Speedup = Foundation ÷ ADJSON "
                + "(higher = ADJSON faster; ⚠︎ = ADJSON slower)._")
        lines.append(
            "_Lazy/partial ADJSON variants (`tape`, `read 2 fields`, `lazy sum`, `walk`) do less work than a "
                + "full typed decode — read them as upper bounds, not like-for-like._")
        lines.append("_Mallocs = total allocations per op; requires jemalloc, shown as “—” when unavailable._")
        return lines.joined(separator: "\n")
    }

    /// Pull the number after `=` from a `#[Label = N, StdDeviation = …]` summary line.
    private static func number(after line: String) -> Double {
        guard let equals = line.firstIndex(of: "=") else { return 0 }
        let afterEquals = line[line.index(after: equals)...].drop(while: { $0 == " " })
        let digits = afterEquals.prefix(while: { $0 != " " && $0 != "," })
        return Double(digits) ?? 0
    }

    private static func ms(_ nanoseconds: Double) -> String { String(format: "%.3f", nanoseconds / 1_000_000.0) }

    private static func speed(_ ratio: Double) -> String {
        ratio >= 1.0 ? String(format: "**%.2f×**", ratio) : String(format: "%.2f× ⚠︎", ratio)
    }

    private static func mallocs(_ foundation: Double, _ adjson: Double) -> String {
        (foundation == 0 && adjson == 0) ? "—" : String(format: "%d → %d", Int(foundation), Int(adjson))
    }
}
