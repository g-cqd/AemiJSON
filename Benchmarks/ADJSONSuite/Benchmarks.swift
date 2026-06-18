import ADJSON
import Benchmark
import Foundation
import OrderedCollections

// The project's benchmark suite, on ordo-one's `Benchmark` framework. Run with
// `ADJSON_DEV=1 swift package benchmark` (add `BENCHMARK_DISABLE_JEMALLOC=1` if jemalloc isn't
// installed; CI installs it for malloc metrics). Benchmarks are grouped `category/name`; ADJSON and
// Foundation variants sit side by side so their p-percentiles are directly comparable. This replaces
// the former homegrown `ADJSONBenchmarks` executable — one suite, statistically rigorous.

// Full lazy walk: read every value through the lazy accessors (the untyped / corpus hot path).
private func adWalk(_ json: JSON) -> Int {
    var sum = 0
    var stack = [json]
    while let node = stack.popLast() {
        if let object = node.object {
            for (_, value) in object { stack.append(value) }
        } else if let array = node.array {
            stack.append(contentsOf: array)
        } else if let i = node.int {
            sum &+= i
        } else if let d = node.double {
            sum &+= Int(d)
        } else if let s = node.string {
            sum &+= s.utf8.count
        } else if let b = node.bool {
            sum &+= b ? 1 : 0
        }
    }
    return sum
}

private func corpusURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)  // Benchmarks/ADJSONSuite/Benchmarks.swift
        .deletingLastPathComponent()  // Benchmarks/ADJSONSuite
        .deletingLastPathComponent()  // Benchmarks
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Benchmarks/Corpus/\(name)")
}

nonisolated(unsafe) let benchmarks = {
    // Time + throughput, CPU time, allocation count, and peak resident memory — so a regression in
    // either CPU or memory (not just wall-clock) shows up. `peakMemoryResident` captures the per-
    // workload RSS high-water (e.g. an untyped `JSONValue`/tape parse vs a Foundation object tree).
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .throughput, .cpuTotal, .mallocCountTotal, .peakMemoryResident])

    // Shared, deterministic payloads (keyed-object-heavy + number-heavy), reused coders.
    let users = makeUsers(2000)
    let userData = try! ADJSON.JSONEncoder().encode(users)
    let usersDocument = try! ADJSON.parse(userData)
    let macroUsers = try! ADJSON.JSONDecoder().decode([MacroUser].self, from: userData)
    let doubles = makeDoubles(200_000)
    let doubleData = try! ADJSON.JSONEncoder().encode(doubles)
    let foundationDecoder = JSONDecoder()
    let foundationEncoder = JSONEncoder()
    // Foundation object graph (NSArray/NSDictionary tree) for the untyped-encode baseline.
    let userFoundationObject = try! JSONSerialization.jsonObject(with: userData)
    // Exact-decimal payloads. `Decimal` exists for values `Double` can't hold, so both regimes are
    // measured: currency-scale "short" (≤9 significant digits), and high-precision "long" (31 digits —
    // beyond UInt64/Double, the case `Decimal` is really for). Foundation special-cases `Decimal` too,
    // so each compares the two exact-decimal paths, not Decimal-vs-Double.
    let decimalShortData = Data(
        ("[" + (0..<20_000).map { "\($0).\(1000 + ($0 &* 7) % 9000)" }.joined(separator: ",") + "]").utf8)
    let decimalLongData = Data(
        ("["
            + (0..<20_000).map { "123456789012345678901234567.\(1000 + ($0 &* 7) % 9000)" }
            .joined(separator: ",") + "]").utf8)
    // ISO-8601 date payload (20k timestamps), serialized once via the `.iso8601` strategy so both
    // decoders parse identical bytes.
    let isoDates = (0..<20_000).map { Date(timeIntervalSince1970: Double(1_600_000_000 + $0)) }
    let isoDateData: Data = {
        var encoder = ADJSON.JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try! encoder.encode(isoDates)
    }()

    // MARK: parse  (untyped: Data -> structure)

    Benchmark("parse/Foundation JSONSerialization") { bm in
        for _ in bm.scaledIterations { blackHole(try! JSONSerialization.jsonObject(with: userData)) }
    }
    Benchmark("parse/ADJSON tape") { bm in
        for _ in bm.scaledIterations { blackHole(try! ADJSON.parse(userData)) }
    }
    Benchmark("parse/ADJSON read 2 fields") { bm in
        for _ in bm.scaledIterations {
            let root = try! ADJSON.parse(userData).root
            var acc = 0
            for user in root.arrayValue {
                acc &+= user.id.intValue
                acc &+= user.login.stringValue.utf8.count
            }
            blackHole(acc)
        }
    }
    Benchmark("parse/ADJSON full walk") { bm in
        for _ in bm.scaledIterations { blackHole(adWalk(try! ADJSON.parse(userData).root)) }
    }
    Benchmark("parse/ADJSON JSONValue tree") { bm in
        for _ in bm.scaledIterations { blackHole(try! JSONValue(parsing: userData)) }
    }

    // MARK: decode  (Data -> [User])

    Benchmark("decode/Foundation") { bm in
        for _ in bm.scaledIterations { blackHole(try! foundationDecoder.decode([User].self, from: userData)) }
    }
    Benchmark("decode/ADJSON Codable") { bm in
        let decoder = ADJSON.JSONDecoder()
        for _ in bm.scaledIterations { blackHole(try! decoder.decode([User].self, from: userData)) }
    }
    Benchmark("decode/ADJSON @JSONCodable") { bm in
        let decoder = ADJSON.JSONDecoder()
        for _ in bm.scaledIterations { blackHole(try! decoder.decode([MacroUser].self, from: userData)) }
    }

    // MARK: encode  ([User] -> Data)

    Benchmark("encode/Foundation") { bm in
        for _ in bm.scaledIterations { blackHole(try! foundationEncoder.encode(users)) }
    }
    Benchmark("encode/ADJSON Codable") { bm in
        let encoder = ADJSON.JSONEncoder()
        for _ in bm.scaledIterations { blackHole(try! encoder.encode(users)) }
    }
    Benchmark("encode/ADJSON @JSONCodable") { bm in
        let encoder = ADJSON.JSONEncoder()
        for _ in bm.scaledIterations { blackHole(try! encoder.encode(macroUsers)) }
    }
    Benchmark("encode/ADJSON JSONValue") { bm in
        let value = try! JSONValue(parsing: userData)
        for _ in bm.scaledIterations { blackHole(try! value.encodedBytes()) }
    }
    Benchmark("encode/ADJSON pretty") { bm in
        var encoder = ADJSON.JSONEncoder()
        encoder.prettyPrinted = true
        for _ in bm.scaledIterations { blackHole(try! encoder.encode(users)) }
    }
    Benchmark("encode/ADJSON sorted") { bm in
        var encoder = ADJSON.JSONEncoder()
        encoder.options = JSONEncodingOptions(keyOrder: .sorted)
        for _ in bm.scaledIterations { blackHole(try! encoder.encode(users)) }
    }
    // Foundation counterparts so each ADJSON encode mode has a like-for-like baseline.
    Benchmark("encode/Foundation JSONSerialization") { bm in
        for _ in bm.scaledIterations { blackHole(try! JSONSerialization.data(withJSONObject: userFoundationObject)) }
    }
    Benchmark("encode/Foundation pretty") { bm in
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        for _ in bm.scaledIterations { blackHole(try! encoder.encode(users)) }
    }
    Benchmark("encode/Foundation sorted") { bm in
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for _ in bm.scaledIterations { blackHole(try! encoder.encode(users)) }
    }

    // MARK: numbers  (number-heavy [Double])

    Benchmark("numbers/Foundation decode") { bm in
        for _ in bm.scaledIterations { blackHole(try! foundationDecoder.decode([Double].self, from: doubleData)) }
    }
    Benchmark("numbers/ADJSON decode") { bm in
        let decoder = ADJSON.JSONDecoder()
        for _ in bm.scaledIterations { blackHole(try! decoder.decode([Double].self, from: doubleData)) }
    }
    Benchmark("numbers/ADJSON lazy sum") { bm in
        for _ in bm.scaledIterations {
            let root = try! ADJSON.parse(doubleData).root
            var sum = 0.0
            root.forEachElement { sum += $0.doubleValue }
            blackHole(sum)
        }
    }

    // MARK: decimal  (exact Decimal from the raw lexeme — short currency-scale and long high-precision)

    Benchmark("decimal/Foundation short") { bm in
        for _ in bm.scaledIterations {
            blackHole(try! foundationDecoder.decode([Decimal].self, from: decimalShortData))
        }
    }
    Benchmark("decimal/ADJSON short") { bm in
        let decoder = ADJSON.JSONDecoder()
        for _ in bm.scaledIterations { blackHole(try! decoder.decode([Decimal].self, from: decimalShortData)) }
    }
    Benchmark("decimal/Foundation long") { bm in
        for _ in bm.scaledIterations { blackHole(try! foundationDecoder.decode([Decimal].self, from: decimalLongData)) }
    }
    Benchmark("decimal/ADJSON long") { bm in
        let decoder = ADJSON.JSONDecoder()
        for _ in bm.scaledIterations { blackHole(try! decoder.decode([Decimal].self, from: decimalLongData)) }
    }

    // MARK: date  (.iso8601 strategy — value-type ISO8601FormatStyle vs Foundation's)

    Benchmark("date/Foundation iso8601 decode") { bm in
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for _ in bm.scaledIterations { blackHole(try! decoder.decode([Date].self, from: isoDateData)) }
    }
    Benchmark("date/ADJSON iso8601 decode") { bm in
        var decoder = ADJSON.JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for _ in bm.scaledIterations { blackHole(try! decoder.decode([Date].self, from: isoDateData)) }
    }

    // MARK: compare  (alloc-free byte compare vs String materialization — the content hot path)

    // DocC-shaped nodes matched on a field name, like the content pipeline's `stringEquals` sites.
    // Short values ("paragraph", 9 B) fit Swift's small-string buffer, so the `==` baseline also
    // avoids a heap alloc there — the `utf8Equals` win is the skipped String construction + decode.
    let typedNodesData = Data(
        ("[" + Array(repeating: #"{"type":"paragraph"}"#, count: 4000).joined(separator: ",") + "]").utf8)
    let typedNodes = try! ADJSON.parse(typedNodesData)
    Benchmark("compare/utf8Equals") { bm in
        for _ in bm.scaledIterations {
            var hits = 0
            typedNodes.root.forEachElement { if $0.type.utf8Equals("paragraph") { hits &+= 1 } }
            blackHole(hits)
        }
    }
    Benchmark("compare/string ==") { bm in
        for _ in bm.scaledIterations {
            var hits = 0
            typedNodes.root.forEachElement { if $0.type.string == "paragraph" { hits &+= 1 } }
            blackHole(hits)
        }
    }
    // Long values (> 15 B) spill the small-string buffer, so `.string ==` pays a heap alloc per
    // compare while `utf8Equals` stays at zero — the malloc-count delta the content team is holding.
    let longLiteral: StaticString = "this-identifier-is-longer-than-the-small-string-buffer"
    let longNode = #"{"type":"this-identifier-is-longer-than-the-small-string-buffer"}"#
    let longNodesData = Data(("[" + Array(repeating: longNode, count: 4000).joined(separator: ",") + "]").utf8)
    let longNodes = try! ADJSON.parse(longNodesData)
    Benchmark("compare/utf8Equals long") { bm in
        for _ in bm.scaledIterations {
            var hits = 0
            longNodes.root.forEachElement { if $0.type.utf8Equals(longLiteral) { hits &+= 1 } }
            blackHole(hits)
        }
    }
    Benchmark("compare/string == long") { bm in
        for _ in bm.scaledIterations {
            var hits = 0
            longNodes.root.forEachElement { if $0.type.string == longLiteral.description { hits &+= 1 } }
            blackHole(hits)
        }
    }

    // Object with many escaped keys: member() compares the lookup key against each candidate, and the
    // escaped-key compare is now alloc-free (was a String per comparison). last-wins scans them all.
    let escapedKeysJSON = "{" + (0..<100).map { #""k\u0041\#($0)":\#($0)"# }.joined(separator: ",") + "}"
    let escapedKeyDoc = try! ADJSON.parse(escapedKeysJSON)  // keys "kAN" decode to "kAN"
    Benchmark("compare/escaped-key lookup") { bm in
        for _ in bm.scaledIterations { blackHole(escapedKeyDoc.root["kA99"].intValue) }
    }

    // MARK: ecma-number  (ECMAScript Number::toString — the .javaScript / JS-stringify path)

    Benchmark("encode/ecma-number") { bm in
        for _ in bm.scaledIterations {
            var sink = 0
            for d in doubles { sink &+= JSONOutput.ecmaNumberToString(d).utf8.count }
            blackHole(sink)
        }
    }
    Benchmark("encode/JSONValue javaScript") { bm in
        let value = try! JSONValue(parsing: doubleData)
        for _ in bm.scaledIterations { blackHole(try! value.encoded(options: .javaScript)) }
    }

    // MARK: borrowed parse  (zero-copy buffer vs the [UInt8] copy it avoids)

    Benchmark("parse/borrowed buffer") { bm in
        for _ in bm.scaledIterations {
            userData.withUnsafeBytes { raw in blackHole(try! ADJSON.parse(raw)) }
        }
    }
    Benchmark("parse/copy then parse") { bm in
        for _ in bm.scaledIterations {
            userData.withUnsafeBytes { raw in blackHole(try! ADJSON.parse([UInt8](raw))) }
        }
    }

    // MARK: - Capabilities with no Foundation equivalent
    // SAX streaming, JSONPath (RFC 9535), JSON Schema, JSON Patch, and off-actor parallel decode have
    // no Foundation counterpart. These measure ADJSON's absolute throughput — the feature edge, not a
    // head-to-head ratio.

    // MARK: stream  (push-SAX event reader — string-heavy, exercises decodeString)

    let userBytes = [UInt8](userData)
    Benchmark("stream/events") { bm in
        for _ in bm.scaledIterations {
            var reader = JSONEventStreamReader()
            var n = 0
            n &+= (try! reader.feed(userBytes)).count
            n &+= (try! reader.finish()).count
            blackHole(n)
        }
    }

    // MARK: query  (JSONPath, RFC 9535 — pre-parsed root)

    Benchmark("query/filter") { bm in
        for _ in bm.scaledIterations { blackHole(try! usersDocument.root.query("$[?(@.followers > 50000)].login")) }
    }
    Benchmark("query/wildcard") { bm in
        for _ in bm.scaledIterations { blackHole(try! usersDocument.root.query("$[*].profile.bio")) }
    }
    Benchmark("query/filter abs-subquery") { bm in
        for _ in bm.scaledIterations {
            blackHole(try! usersDocument.root.query("$[?(@.followers > $[0].followers)]"))
        }
    }
    Benchmark("query/slice small") { bm in
        // A tiny slice off a 2000-element array — the win is not materializing all 2000 elements.
        for _ in bm.scaledIterations { blackHole(try! usersDocument.root.query("$[0:10]")) }
    }
    Benchmark("query/slice step") { bm in
        for _ in bm.scaledIterations { blackHole(try! usersDocument.root.query("$[0:200:5]")) }
    }
    Benchmark("query/compile 4 paths") { bm in
        let paths = [
            "$.store.book[*].title",
            #"$[?(@.followers > 50000 && @.login != "abc")].login"#,
            "$..profile.bio",
            "$['a']['b'][0:10:2].c",
        ]
        for _ in bm.scaledIterations {
            for path in paths { blackHole(try? JSONPath(path)) }
        }
    }

    // MARK: schema  (JSON Schema validate — compile once, validate many)

    let userArraySchema = try! JSONSchema(parsing: "{\"type\":\"array\",\"items\":\(MacroUser.__adjsonSchemaText)}")
    Benchmark("schema/validate") { bm in
        for _ in bm.scaledIterations { blackHole(userArraySchema.isValid(usersDocument.root)) }
    }

    // MARK: mutate  (JSON Patch apply)

    let patch = try! JSONPatch(
        Data(
            #"[{"op":"replace","path":"/0/login","value":"x"},{"op":"add","path":"/0/flagged","value":true}]"#
                .utf8))
    let usersValue = try! JSONValue(parsing: userData)
    Benchmark("mutate/JSONPatch apply") { bm in
        for _ in bm.scaledIterations { blackHole(try! patch.apply(to: usersValue)) }
    }

    // MARK: concurrent  (off-actor parallel array decode)

    Benchmark("concurrent/serial decode") { bm in
        for _ in bm.scaledIterations { blackHole(try! ADJSON.JSONDecoder().decode([User].self, from: usersDocument)) }
    }
    Benchmark("concurrent/parallel decode") { bm async in
        for _ in bm.scaledIterations {
            blackHole(try! await ADJSON.decodeArrayConcurrently(User.self, from: usersDocument, minimumBatch: 256))
        }
    }

    // MARK: object-model  (why JSONValue.object is an OrderedDictionary)

    let objectKeys = ["id", "login", "name", "email", "followers", "following", "isAdmin", "score", "tags", "profile"]
    Benchmark("object-model/Dictionary build+lookup") { bm in
        for _ in bm.scaledIterations {
            var dict = [String: Int](minimumCapacity: objectKeys.count)
            for (i, k) in objectKeys.enumerated() { dict[k] = i }
            var sink = 0
            for k in objectKeys { sink &+= dict[k] ?? 0 }
            blackHole(sink)
        }
    }
    Benchmark("object-model/OrderedDictionary build+lookup") { bm in
        for _ in bm.scaledIterations {
            var dict = OrderedDictionary<String, Int>(minimumCapacity: objectKeys.count)
            for (i, k) in objectKeys.enumerated() { dict[k] = i }
            var sink = 0
            for k in objectKeys { sink &+= dict[k] ?? 0 }
            blackHole(sink)
        }
    }

    // MARK: corpus  (real-world files; registered only when the fixtures are present). Each file runs
    // the full lifecycle on real data — parse, untyped materialize, query, patch, and re-encode — with
    // the Foundation baseline next to each ADJSON variant that has one, so the wins (and the parity
    // cases) hold up beyond the synthetic payload.
    let corpusQuery = [  // a realistic per-file JSONPath (RFC 9535) extraction
        "twitter.json": "$.statuses[*].user.screen_name",
        "citm_catalog.json": "$..name",
        "canada.json": "$.features[*].geometry.type",
        "github_events.json": "$[*].actor.login",
        "gsoc-2018.json": "$[*].name",
        "marine_ik.json": "$.images[*].name",
        "twitterescaped.json": "$.statuses[*].user.screen_name",
        "numbers.json": "$[0:1000]",
    ]
    // A small RFC 6902 patch — add a top-level key for object roots, append for array roots.
    let corpusObjectPatch = try! JSONPatch(Data(#"[{"op":"add","path":"/_bench","value":true}]"#.utf8))
    let corpusArrayPatch = try! JSONPatch(Data(#"[{"op":"add","path":"/-","value":true}]"#.utf8))

    let corpusFiles = [
        "twitter.json", "citm_catalog.json", "canada.json", "github_events.json", "gsoc-2018.json",
        "marine_ik.json", "twitterescaped.json", "numbers.json",
    ]
    for file in corpusFiles {
        guard let data = try? Data(contentsOf: corpusURL(file)) else { continue }
        let name = file.replacingOccurrences(of: ".json", with: "")
        // Forms parsed once and reused, so encode/query/patch measure only their own work.
        let adValue = try! JSONValue(parsing: data)
        let adDocument = try! ADJSON.parse(data)
        let fnObject = try! JSONSerialization.jsonObject(with: data)
        let query = corpusQuery[file]!
        var patch = corpusObjectPatch
        if case .array = adValue { patch = corpusArrayPatch }

        // parse  (Data -> structure)
        Benchmark("corpus/\(name) Foundation") { bm in
            for _ in bm.scaledIterations { blackHole(try! JSONSerialization.jsonObject(with: data)) }
        }
        Benchmark("corpus/\(name) ADJSON tape") { bm in
            for _ in bm.scaledIterations { blackHole(try! ADJSON.parse(data)) }
        }
        Benchmark("corpus/\(name) ADJSON walk") { bm in
            for _ in bm.scaledIterations { blackHole(adWalk(try! ADJSON.parse(data).root)) }
        }
        Benchmark("corpus/\(name) ADJSON JSONValue") { bm in
            for _ in bm.scaledIterations { blackHole(try! JSONValue(parsing: data)) }
        }
        // encode  (structure -> Data), re-serializing the pre-parsed forms
        Benchmark("corpus/\(name) encode ADJSON") { bm in
            for _ in bm.scaledIterations { blackHole(try! adValue.encodedBytes()) }
        }
        Benchmark("corpus/\(name) encode ADJSON cursor") { bm in
            for _ in bm.scaledIterations { blackHole(try! adDocument.root.encodedBytes()) }
        }
        Benchmark("corpus/\(name) encode Foundation") { bm in
            for _ in bm.scaledIterations { blackHole(try! JSONSerialization.data(withJSONObject: fnObject)) }
        }
        // manipulate  (query + patch) on the pre-parsed forms
        Benchmark("corpus/\(name) query ADJSON") { bm in
            for _ in bm.scaledIterations { blackHole(try! adDocument.root.query(query)) }
        }
        Benchmark("corpus/\(name) patch ADJSON") { bm in
            for _ in bm.scaledIterations { blackHole(try! patch.apply(to: adValue)) }
        }
    }
}
