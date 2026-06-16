import Foundation
import PackagePlugin

/// `swift package coverage-check [--floor N] [--config debug|release] [--bin-path PATH]` — the line-
/// coverage gate, in Swift instead of inline shell/awk/python. It reads the profile produced by a
/// prior `swift test --enable-code-coverage`, prints the per-file `llvm-cov` report, parses the total
/// line-coverage percentage from `llvm-cov export`, and fails (non-zero exit) when it is below the
/// floor. The shipped library sources are measured; `Tests`, `.build`, and `Benchmarks` are excluded.
///
/// macOS-only: it shells out to `xcrun llvm-cov`, which the Darwin toolchain provides.
@main
struct CoverageCheckPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var floor = 80.0
        var config = "debug"
        var binPathOverride: String?
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--floor": if let value = iterator.next(), let parsed = Double(value) { floor = parsed }
            case "--config": if let value = iterator.next() { config = value }
            case "--bin-path": binPathOverride = iterator.next()
            default: break
            }
        }

        let fileManager = FileManager.default
        let binDir =
            binPathOverride.map { URL(fileURLWithPath: $0) }
            ?? context.package.directoryURL.appending(path: ".build/\(config)")

        let profile = binDir.appending(path: "codecov/default.profdata")
        guard fileManager.fileExists(atPath: profile.path) else {
            Diagnostics.error(
                "no coverage profile at \(profile.path); run `swift test --enable-code-coverage` first")
            throw CoverageError.noProfile
        }
        guard
            let bundle = (try? fileManager.contentsOfDirectory(at: binDir, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "xctest" })
        else {
            Diagnostics.error("no .xctest bundle under \(binDir.path)")
            throw CoverageError.noBundle
        }
        // macOS bundle layout: `<name>.xctest/Contents/MacOS/<name>`. Fall back to the bundle path
        // itself (the Linux executable layout) if that inner path is absent.
        let name = bundle.deletingPathExtension().lastPathComponent
        let macOSTool = bundle.appending(path: "Contents/MacOS/\(name)")
        let tool = fileManager.fileExists(atPath: macOSTool.path) ? macOSTool : bundle

        let ignore = "-ignore-filename-regex=(Tests|\\.build|Benchmarks)/"
        let common = [tool.path, "-instr-profile", profile.path, ignore]

        // Human-readable per-file table for the CI job summary.
        let report = try runCapturing("/usr/bin/xcrun", ["llvm-cov", "report"] + common)
        print("## Code coverage\n\n```text\n\(report.trimmingCharacters(in: .newlines))\n```")

        // Machine-readable total for the gate.
        let exported = try runCapturing("/usr/bin/xcrun", ["llvm-cov", "export", "-summary-only"] + common)
        guard let percent = Self.lineCoveragePercent(fromExportJSON: exported) else {
            Diagnostics.error("could not parse line coverage from `llvm-cov export`")
            throw CoverageError.parseFailure
        }

        let percentText = String(format: "%.2f", percent)
        let floorText = String(format: "%.0f", floor)
        print("\nLine coverage: **\(percentText)%** (floor \(floorText)%)")
        // Tolerate float noise at the boundary; only a genuine shortfall fails.
        if percent < floor - 1e-9 {
            Diagnostics.error("line coverage \(percentText)% is below the floor \(floorText)%")
            throw CoverageError.belowFloor
        }
    }

    /// Pull `data[0].totals.lines.percent` from `llvm-cov export` JSON.
    static func lineCoveragePercent(fromExportJSON json: String) -> Double? {
        guard let data = json.data(using: .utf8),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let entries = root["data"] as? [[String: Any]],
            let totals = entries.first?["totals"] as? [String: Any],
            let lines = totals["lines"] as? [String: Any],
            let percent = lines["percent"] as? Double
        else { return nil }
        return percent
    }

    /// Run a tool and return its standard output as a string. Drains the pipe before waiting so large
    /// reports cannot deadlock on a full pipe buffer.
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

enum CoverageError: Error {
    case noProfile, noBundle, parseFailure, belowFloor
}
