import Foundation
import PackagePlugin

/// `swift package lint` — the single source of truth for the project's lint rules:
///   1. a formatting gate across the package via `swift format lint --strict` (project `.swift-format`);
///   2. shipped-library discipline in `Sources/ADJSON` AND `Sources/ADJSONCore` (the unsafe-pointer
///      engine is a shipped product too):
///        - **no force unwrap / force cast / force try**, enforced by swift-format's *AST* rules
///          (`NeverForceUnwrap`, `NeverUseForceTry`) run with the project config plus those two rules
///          switched on. This catches every `x!` / `as!` / `try!` — not a fixed pattern set — and a
///          reviewed exception opts out with a `// swift-format-ignore: NeverForceUnwrap` line above it.
///        - **no locale-sensitive `strtod`**, which is not a force-unwrap, so a small textual scan covers
///          it; a reviewed case opts out with a trailing `// lint:allow` comment.
///        - **no ad-hoc number formatting**: `String(format:)` anywhere, or `snprintf`/`vsnprintf`
///          outside `JSONOutput.swift`, must instead route through the single-source `JSONOutput` /
///          `JSONShortest` byte emitters so number/locale formatting can't drift (same `// lint:allow`).
/// Tests, benchmarks, macros, and the fuzz target are exempt from rule 2.
@main
struct LintPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let root = context.package.directoryURL
        let swift = try context.tool(named: "swift")
        var failed = false

        // 1. Formatting gate across the package (project `.swift-format`).
        let paths = ["Sources", "Tests", "Plugins", "Package.swift"].map { root.appending(path: $0).path }
        if run(swift, ["format", "lint", "--strict", "--recursive"] + paths) != 0 { failed = true }

        // 2a. Force-unwrap / force-cast / force-try discipline — AST-based, scoped to the two shipped
        //     library targets. The config is the project `.swift-format` with `NeverForceUnwrap` +
        //     `NeverUseForceTry` switched on, so there are no defaults-driven false positives and the
        //     rule set never drifts from the checked-in config.
        let libPaths = ["Sources/ADJSON", "Sources/ADJSONCore"].map { root.appending(path: $0).path }
        if let strict = strictConfig(root: root, work: context.pluginWorkDirectoryURL) {
            let status = run(
                swift, ["format", "lint", "--strict", "--configuration", strict.path, "--recursive"] + libPaths)
            if status != 0 { failed = true }
        } else {
            Diagnostics.error("could not derive the strict force-unwrap config from .swift-format")
            failed = true
        }

        // 2b. Locale-sensitive `strtod` ban (not a force-unwrap, so swift-format can't express it).
        if scanForbiddenStrtod(root: root) { failed = true }

        // 2c. Ad-hoc number / locale formatting ban — keep emission in the single-source `JSONOutput`.
        if scanForbiddenNumberFormatting(root: root) { failed = true }

        if failed {
            Diagnostics.error("lint failed")
        } else {
            print("lint clean")
        }
    }

    /// Run `swift <args>` synchronously; returns the exit status (non-zero ⇒ failure).
    private func run(_ swift: PluginContext.Tool, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = swift.url
        process.arguments = args
        do {
            try process.run()
        } catch {
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Derive a swift-format config in the plugin's work directory: the project `.swift-format` with the
    /// force-unwrap / force-try AST rules switched on. Returns nil if the base config can't be read,
    /// parsed, or rewritten — the caller treats that as a failure rather than silently skipping the check.
    private func strictConfig(root: URL, work: URL) -> URL? {
        let base = root.appending(path: ".swift-format")
        guard let data = try? Data(contentsOf: base),
            var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        var rules = (json["rules"] as? [String: Any]) ?? [:]
        rules["NeverForceUnwrap"] = true
        rules["NeverUseForceTry"] = true
        json["rules"] = rules
        guard let out = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        let dest = work.appending(path: "strict.swift-format")
        guard (try? out.write(to: dest)) != nil else { return nil }
        return dest
    }

    /// Scan the shipped library targets for the locale-sensitive `strtod(` C call. Returns true if any
    /// un-annotated use is found (each is also reported as a diagnostic).
    private func scanForbiddenStrtod(root: URL) -> Bool {
        var found = false
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
                where line.contains("strtod(") && !line.contains("lint:allow") {
                    Diagnostics.error(
                        "\(file.lastPathComponent):\(offset + 1): locale-sensitive strtod is banned in shipped "
                            + "library code (annotate a reviewed case with // lint:allow)")
                    found = true
                }
            }
        }
        return found
    }

    /// Scan the shipped library targets for ad-hoc number / locale-sensitive formatting that must instead
    /// route through the single-source `JSONOutput` / `JSONShortest` byte emitters: any `String(format:`
    /// (locale-sensitive and a bypass), and any `snprintf` / `vsnprintf` outside `JSONOutput.swift` (whose
    /// `%!.15g` SQLite formatter is the one sanctioned printf use). A reviewed case opts out with
    /// `// lint:allow`. Returns true if any un-annotated use is found (each is reported as a diagnostic).
    private func scanForbiddenNumberFormatting(root: URL) -> Bool {
        var found = false
        for target in ["Sources/ADJSON", "Sources/ADJSONCore"] {
            let lib = root.appending(path: target)
            guard let walker = FileManager.default.enumerator(at: lib, includingPropertiesForKeys: nil) else {
                continue
            }
            while let file = walker.nextObject() as? URL {
                guard file.pathExtension == "swift",
                    let text = try? String(contentsOf: file, encoding: .utf8)
                else { continue }
                let isJSONOutput = file.lastPathComponent == "JSONOutput.swift"
                for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    if line.contains("lint:allow") { continue }
                    if line.contains("String(format:") {
                        Diagnostics.error(
                            "\(file.lastPathComponent):\(offset + 1): String(format:) is banned in shipped library "
                                + "code — route number/string emission through JSONOutput (annotate with // lint:allow)"
                        )
                        found = true
                    }
                    if !isJSONOutput, line.contains("snprintf(") {
                        Diagnostics.error(
                            "\(file.lastPathComponent):\(offset + 1): printf-style number formatting belongs in "
                                + "JSONOutput (the single-source emitter); annotate a reviewed case with // lint:allow")
                        found = true
                    }
                }
            }
        }
        return found
    }
}
