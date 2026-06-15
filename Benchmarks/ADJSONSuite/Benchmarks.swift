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
    Benchmark.defaultConfiguration = .init(metrics: [.wallClock, .throughput, .mallocCountTotal])

    // Shared, deterministic payloads (keyed-object-heavy + number-heavy), reused coders.
    let users = makeUsers(2000)
    let userData = try! ADJSON.JSONEncoder().encode(users)
    let usersDocument = try! ADJSON.parse(userData)
    let macroUsers = try! ADJSON.JSONDecoder().decode([MacroUser].self, from: userData)
    let doubles = makeDoubles(200_000)
    let doubleData = try! ADJSON.JSONEncoder().encode(doubles)
    let foundationDecoder = JSONDecoder()
    let foundationEncoder = JSONEncoder()

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

    // MARK: corpus  (real-world files; registered only when the fixtures are present)

    for file in ["twitter.json", "citm_catalog.json", "canada.json"] {
        guard let data = try? Data(contentsOf: corpusURL(file)) else { continue }
        let name = file.replacingOccurrences(of: ".json", with: "")
        Benchmark("corpus/\(name) Foundation") { bm in
            for _ in bm.scaledIterations { blackHole(try! JSONSerialization.jsonObject(with: data)) }
        }
        Benchmark("corpus/\(name) ADJSON tape") { bm in
            for _ in bm.scaledIterations { blackHole(try! ADJSON.parse(data)) }
        }
        Benchmark("corpus/\(name) ADJSON walk") { bm in
            for _ in bm.scaledIterations { blackHole(adWalk(try! ADJSON.parse(data).root)) }
        }
    }
}
