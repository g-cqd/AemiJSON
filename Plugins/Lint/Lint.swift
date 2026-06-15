import Foundation
import PackagePlugin

/// `swift package lint` — the single source of truth for the project's lint rules (formerly
/// `scripts/lint.sh`):
///   1. formatting gate via `swift format lint --strict`, and
///   2. shipped-library discipline: no force-unwrap / force-try / force-cast / locale-sensitive
///      `strtod` in the shipped library targets `Sources/ADJSON` AND `Sources/ADJSONCore` (the
///      unsafe-pointer engine is a shipped product too). Tests, benchmarks, macros, and the fuzz
///      target are exempt. A single reviewed exception can be annotated with a trailing
///      `// lint:allow` comment (used for the engine's one guarded `baseAddress!`).
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

        // 2. Shipped-library discipline across BOTH shipped library targets.
        let banned = try Regex(#"(\btry!|\bas!|baseAddress!|\.first!|strtod\()"#)
        for target in ["Sources/ADJSON", "Sources/ADJSONCore"] {
            let lib = root.appending(path: target)
            guard let walker = FileManager.default.enumerator(at: lib, includingPropertiesForKeys: nil) else {
                continue
            }
            while let file = walker.nextObject() as? URL {
                guard file.pathExtension == "swift",
                    let text = try? String(contentsOf: file, encoding: .utf8)
                else { continue }
                for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                // A reviewed exception opts out with a trailing `// lint:allow` marker.
                where line.contains(banned) && !line.contains("lint:allow") {
                    Diagnostics.error(
                        "\(file.lastPathComponent):\(offset + 1): force unwrap / force try / force cast / "
                            + "strtod is banned in shipped library code (annotate a reviewed case with // lint:allow)")
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
