import Foundation
import PackagePlugin

/// `swift package lint` — the single source of truth for the project's lint rules (formerly
/// `scripts/lint.sh`):
///   1. formatting gate via `swift format lint --strict`, and
///   2. shipped-library discipline: no force-unwrap / force-try / force-cast / locale-sensitive
///      `strtod` in `Sources/ADJSON` (tests and benchmarks are exempt).
@main
struct LintPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let root = context.package.directoryURL
        var failed = false

        // 1. Formatting gate across the package.
        let paths = ["Sources", "Tests", "Plugins", "Package.swift"].map { root.appending(path: $0).path }
        let swift = try context.tool(named: "swift")
        let format = Process()
        format.executableURL = swift.url
        format.arguments = ["format", "lint", "--strict", "--recursive"] + paths
        try format.run()
        format.waitUntilExit()
        if format.terminationStatus != 0 { failed = true }

        // 2. Shipped-library discipline (Sources/ADJSON only).
        let banned = try Regex(#"(\btry!|\bas!|baseAddress!|\.first!|strtod\()"#)
        let lib = root.appending(path: "Sources/ADJSON")
        if let walker = FileManager.default.enumerator(at: lib, includingPropertiesForKeys: nil) {
            while let file = walker.nextObject() as? URL {
                guard file.pathExtension == "swift",
                    let text = try? String(contentsOf: file, encoding: .utf8)
                else { continue }
                for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.contains(banned) {
                    Diagnostics.error(
                        "\(file.lastPathComponent):\(offset + 1): force unwrap / force try / force cast / "
                            + "strtod is banned in Sources/ADJSON")
                    failed = true
                }
            }
        }

        if failed {
            Diagnostics.error("lint failed")
        } else {
            print("lint clean")
        }
    }
}
