// libFuzzer entry point for ADJSON. Built only when `ADJSON_FUZZ` is set (see `Package.swift`),
// with `-sanitize=fuzzer -parse-as-library`, so the default `swift build` is never asked to link a
// `main`-less executable. The libFuzzer runtime provides `main` and drives `LLVMFuzzerTestOneInput`
// with mutated inputs seeded from the vendored corpora + CTS.
//
// The contract under test is *total memory safety*: every entry below must, for ANY byte string,
// either succeed or throw — never trap, never read out of bounds, never loop unbounded. Errors are
// the expected outcome for malformed input and are swallowed; a crash is a finding.

import ADJSON

// A representative macro fast-path type (recursive, so it exercises the depth-guarded
// `fastArray` / `decodeValue` paths) for the Codable decode entry point below.
@JSONCodable
struct FuzzRecord: Codable {
    var id: Int
    var name: String?
    var tags: [String]
    var nested: [FuzzRecord]
}

@_cdecl("LLVMFuzzerTestOneInput")
public func LLVMFuzzerTestOneInput(_ start: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    guard let start, count > 0 else { return 0 }
    let bytes = [UInt8](UnsafeBufferPointer(start: start, count: count))

    // Tape parse in every grammar mode.
    for options in [JSONParseOptions.strict, .lenient, .json5, .iJSON] {
        if let document = try? ADJSON.parse(bytes, options: options) {
            // Exercise lazy navigation, descendant query, and (strict) materialize + re-encode.
            _ = JSONPathEvaluator_descendAll(document.root)
            if case .strict = options.validation {
                let value = JSONValue(document.root)
                _ = try? value.encodedBytes()
            }
        }
    }

    // Value-model parse from the same bytes interpreted as UTF-8.
    let text = String(decoding: bytes, as: UTF8.self)
    _ = try? JSONValue(parsing: text)

    // Query compilers over the bytes interpreted as a path string.
    if let path = try? JSONPath(text), let document = try? ADJSON.parse(bytes) {
        _ = path.query(document.root)
    }
    _ = try? SQLiteJSONPath(text)

    // Codable decoder — the macro fast path + nested collections, all depth-guarded.
    let decoder = ADJSON.JSONDecoder()
    _ = try? decoder.decode(FuzzRecord.self, from: bytes)
    _ = try? decoder.decode([[Int]].self, from: bytes)
    _ = try? decoder.decode([String: Double].self, from: bytes)

    // Schema compile + validate, JSON Patch (RFC 6902), and Merge-Patch (RFC 7396): treat the parsed
    // document as a schema and validate it against itself, then apply it as a patch. These are the
    // recursive paths whose depth guards must fail closed rather than overflow.
    if let document = try? ADJSON.parse(bytes) {
        let schema = JSONSchema(document.root)
        _ = schema.validate(document.root)
        let value = JSONValue(document.root)
        if let patch = try? JSONPatch(document.root) { _ = try? patch.apply(to: value) }
        _ = JSONMergePatch.apply(value, to: value)
    }

    // Push (chunked) SAX reader: feed the bytes in small chunks, then finish — the resumable
    // tokenizer path the pull reader and tape parser don't cover.
    var stream = JSONEventStreamReader()
    var offset = 0
    let chunk = 7
    while offset < bytes.count {
        let end = Swift.min(offset + chunk, bytes.count)
        guard (try? stream.feed(Array(bytes[offset..<end]))) != nil else { break }
        offset = end
    }
    _ = try? stream.finish()

    return 0
}

// Force a full lazy walk (every accessor over every node) to stress the unsafe byte/tape reads.
private func JSONPathEvaluator_descendAll(_ root: JSON) -> Int {
    var sum = 0
    var stack = [root]
    while let node = stack.popLast() {
        if let i = node.int { sum &+= i } else if let d = node.double { sum &+= Int(d.isFinite ? d : 0) }
        _ = node.string
        _ = node.bool
        if node.isArray {
            node.forEachElement { stack.append($0) }
        } else if node.isObject {
            node.forEachMember { _, value in stack.append(value) }
        }
    }
    return sum
}
