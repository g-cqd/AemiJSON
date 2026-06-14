import Foundation
import PackagePlugin

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// `swift package fetch-fixtures` — downloads the third-party conformance/benchmark corpora that
/// are not vendored in-repo (replaces `scripts/fetch-fixtures.sh`). Downloads use `URLSession`;
/// the one tarball (nst/JSONTestSuite) is expanded with `tar`, since Foundation has no native
/// archive API. Needs network + package-write permissions; CI passes
/// `--allow-network-connections all --allow-writing-to-package-directory`.
@main
struct FetchFixturesPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let root = context.package.directoryURL
        let fm = FileManager.default
        // Ephemeral: no on-disk URL cache (avoids the SQLite cache chatter and keeps fetches clean).
        let session = URLSession(configuration: .ephemeral)

        func download(_ urlString: String, to relativePath: String) async throws {
            guard let url = URL(string: urlString) else { return }
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Diagnostics.error("download failed (HTTP \(http.statusCode)): \(urlString)")
                return
            }
            let dest = root.appending(path: relativePath)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
        }

        // simdjson / nativejson-benchmark corpus + RFC 9535 JSONPath compliance suite.
        let simd = "https://raw.githubusercontent.com/simdjson/simdjson/master/jsonexamples"
        try await download("\(simd)/twitter.json", to: "Benchmarks/Corpus/twitter.json")
        try await download("\(simd)/citm_catalog.json", to: "Benchmarks/Corpus/citm_catalog.json")
        try await download(
            "https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/canada.json",
            to: "Benchmarks/Corpus/canada.json")
        try await download(
            "https://raw.githubusercontent.com/jsonpath-standard/jsonpath-compliance-test-suite/main/cts.json",
            to: "Tests/ADJSONTests/Resources/JSONPathCTS/cts.json")

        // nst/JSONTestSuite: download the tarball, then expand it with `tar` and copy the parsing cases.
        let suite = root.appending(path: "Tests/ADJSONTests/Resources/JSONTestSuite")
        try fm.createDirectory(at: suite, withIntermediateDirectories: true)
        let tmp = root.appending(path: ".build/_fixtures-tmp")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        if let url = URL(string: "https://github.com/nst/JSONTestSuite/archive/refs/heads/master.tar.gz") {
            let (data, _) = try await session.data(from: url)
            let tarball = tmp.appending(path: "jsontestsuite.tar.gz")
            try data.write(to: tarball)

            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            tar.arguments = ["tar", "-xzf", tarball.path, "-C", tmp.path]
            try tar.run()
            tar.waitUntilExit()

            let parsing = tmp.appending(path: "JSONTestSuite-master/test_parsing")
            if let items = try? fm.contentsOfDirectory(at: parsing, includingPropertiesForKeys: nil) {
                for file in items where file.pathExtension == "json" {
                    let dest = suite.appending(path: file.lastPathComponent)
                    try? fm.removeItem(at: dest)
                    try fm.copyItem(at: file, to: dest)
                }
            }
        }

        print("Fixtures fetched into Benchmarks/Corpus and Tests/ADJSONTests/Resources.")
    }
}
