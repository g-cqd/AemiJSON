# Depth Safety and Stack Exhaustion

How AemiJSON handles deeply nested input — a small payload (`[[[…]]]`) that tries to exhaust the call
stack (CWE-674, a recursion DoS) — and why it goes far past Foundation's hard cap.

## The short version

A *recursive-descent* JSON parser pushes one (or more) call frames per nesting level, so a tiny
input of a few thousand `[` can overflow the thread stack and crash the process with an uncatchable
signal. Foundation defuses this in its **scanner** with a hard cap: a document nested deeper than
**512** throws `DecodingError.dataCorrupted` ("Too many nested arrays or dictionaries"). But the
*decoder* layer above it has no such guard — a `Decodable` that recurses through
`singleValueContainer` (adding no JSON structure) overflows at ~12k–19k levels.

AemiJSON is built the opposite way: the **parser is iterative** (an explicit heap stack, not call
frames), so nesting costs heap, not stack. With ``/AemiJSONCore/JSONParseOptions/maxDepth`` raised, parsing, lazy
navigation, SAX reading, and JSONPath descent all handle **1,000,000+** levels with no overflow —
roughly 2000× Foundation's cap. The only stack-using consumer is the Codable decoder (the protocol
mandates recursion), and it is bounded by an explicit guard that **throws instead of crashing**.

## Which paths use the stack?

| Path | Strategy | Deep-input behavior |
|---|---|---|
| Tape parse (``/AemiJSONCore/AemiJSON/parse(_:options:)-([UInt8],_)``) | **iterative** | survives any depth up to `maxDepth`; then throws `.depthExceeded` |
| Lazy navigation (`json.a.b…`) | **iterative** | O(1) per step, no recursion |
| SAX (``/AemiJSONCore/JSONEventReader`` / ``/AemiJSONCore/JSONEventStreamReader``) | **iterative** | survives any depth |
| JSONPath `..` descent | **iterative** | survives any depth |
| ``/AemiJSONCore/JSONValue`` materialize (``/AemiJSONCore/JSONValue/init(_:)``) | **iterative** build | builds any depth; but see *tree deallocation* below |
| ``/AemiJSONCore/JSONValue`` serialize (``/AemiJSONCore/JSONValue/encodedBytes(options:)``) | **iterative** | serializes any holdable tree |
| ``/AemiJSONCore/JSONValue`` equality (`==`) | **iterative** | compares any depth (an explicit work-stack) |
| **Codable decode** (``AemiJSON/JSONDecoder``) | recursive (protocol) | **throws** past `maxDecodingDepth` (default 64 — sized for 512 KiB stacks) |
| **Codable encode** (``AemiJSON/JSONEncoder``) | recursive (protocol) | **throws** past `maxEncodingDepth` (default 2048) |
| Concurrent decode (`AemiJSON.decodeArrayConcurrently`) | recursive (per element, on the pool) | **throws** past `maxDecodingDepth` (default 64, as above) |
| JSON Schema validate | recursive | **fails closed** (records a `ValidationError`) past an independent cap (256) |
| JSONPath filter parse (`length(length(…))`, `[?…[?…]]`) | recursive | **throws** `JSONPathError` past a cap (64) |
| JSON Patch / Merge-Patch / SQLite mutate | recursive (per path / patch level) | **fails closed** past a cap (256): patch throws `JSONPatchError.depthExceeded`, merge/SQLite degrade safely |

### Tree deallocation is the one inherent limit

Building a ``/AemiJSONCore/JSONValue`` is iterative, but the resulting value tree — like *any* recursive Swift
value type, and like Foundation's decoded `[Any]` / `NSDictionary` graphs — is **released
recursively** by ARC. Holding a tree deeper than ~30–40k levels (less on a small-stack worker
thread) and letting it deallocate overflows the stack. The fix is structural, not a bug to patch:
process very deep documents through the **lazy ``/AemiJSONCore/JSON`` view or the SAX readers**, which never
materialize a tree, or bound input depth. Dismantling a deep tree by walking it down a level at a
time (as opposed to a single bulk release) also avoids the recursion.

## The decoder guard

The Codable path is unavoidably recursive (each `init(from:)` decodes its children). AemiJSON caps
that native recursion with ``AemiJSON/JSONDecoder/maxDecodingDepth`` (default **64**), independent of
`maxDepth`: past it, decoding throws a catchable `DecodingError` rather than overflowing. So you can
raise `maxDepth` to *parse / navigate* very deep documents iteratively, while a deeply nested (or
self-referential) `Decodable` still **fails closed**. Every nested value other than a scalar counts
one level, so an array of objects nests two levels deep.

The default is sized for the stack most decoding runs on: actors and the Swift cooperative pool run
on 512 KiB threads, not the ~8 MB main thread. Measured on a thread created with a 512 KiB stack, in
decode levels (the unit `maxDecodingDepth` counts):

| Shape | Debug overflow | Release overflow |
|---|--:|--:|
| Keyed class with 32 optional fields and a recursive child | ~150 levels | ~440 levels |
| Keyed class with 16 optional fields | ~185 levels | ~450 levels |
| Untyped JSON value decoded through a `try?` chain (objects) | ~220 levels | ~490 levels |
| `@JSONCodable` struct nesting through an array | ~650 levels | ~4,750 levels |

Under the former default (2048) the guard fired only after each of these had overflowed, and in a
debug build all but the `@JSONCodable` shape overflow at a nesting the default parser limit (512)
accepts. At 64 the heaviest of them stays under half of a debug build's stack. Raise the cap on a thread with a known large stack: an 8 MiB stack (the main thread's size)
holds ~2,400 levels of the 32-field class in a debug build.

```swift
var decoder = AemiJSON.JSONDecoder()
decoder.options = JSONParseOptions(maxDepth: 100_000)  // iterative parser accepts deep input
decoder.maxDecodingDepth = 1_000                        // raised: this decoder runs on the main thread
// A 100k-deep document is rejected with a DecodingError rather than overflowing the stack.
```

## The failure-safety policy at a glance

AemiJSON keeps the *iterative* paths effectively unbounded (limited only by ``/AemiJSONCore/JSONParseOptions/maxDepth``,
which costs heap, not stack) and gives every *unavoidably recursive* path its own hard cap that
**fails closed** — a catchable error, never a crash — independent of `maxDepth`. Each default is sized
for the call site: the recursive frames are heavy where the cap is low.

| Limit | Default | Applies to | Past it |
|---|---|---|---|
| ``/AemiJSONCore/JSONParseOptions/maxDepth`` | 512 | iterative parse / lazy / SAX / JSONPath descent | throws `JSONError.depthExceeded` |
| ``AemiJSON/JSONDecoder/maxDecodingDepth`` | 64 | recursive Codable decode (512 KiB actor / pool stacks) | throws `DecodingError` |
| ``AemiJSON/JSONEncoder/maxEncodingDepth`` | 2048 | recursive Codable encode (main thread) | throws `EncodingError` |
| concurrent-decode `maxDecodingDepth` | 64 | per-element decode on the cooperative pool (512 KiB stacks) | throws `DecodingError` |
| schema validation cap | 256 | recursive schema + instance walk (heavy frames) | records a `ValidationError` |
| JSONPath filter-parse cap | 64 | nested `length()` / bracket-filter recursion | throws `JSONPathError` |
| value-mutation cap | 256 | JSON Patch / Merge-Patch / SQLite path recursion | patch throws; merge/SQLite degrade safely |

The recursive caps differ because frame sizes and target stacks differ: the Codable decode cap is
sized for the 512 KiB stacks of actors and the cooperative pool (so 64), the encode cap for the
~8 MB main thread (so 2048), and a schema-validation frame copies a whole compiled node (so 256).
Lower any of them when running untrusted input on a smaller stack; raise the decode/encode caps on a
thread with a known-large stack.

### Can the fixed caps be raised?

The *configurable* limits — `maxDepth`, the Codable `maxDecodingDepth` / `maxEncodingDepth`, and the
concurrent decode cap — are meant to be tuned by the caller for their stack. The *fixed* caps — schema
validation (256), value mutation (256), and the JSONPath filter-parse cap (64) — are deliberately
**not** raised and are not exposed as global knobs:

- They already accept every realistic input. A 256-segment JSON Pointer, a 256-deep schema instance,
  or a 64-deep `length()` nest is already pathological; the cap rejects the pathological case, it does
  not limit real data.
- Each fixed cap is a single constant that runs on **whatever thread the caller chose**. The values
  are calibrated for the ~8 MB main thread; the same recursion on a ~512 KB worker (a cooperative-pool
  thread) holds far fewer frames, and under a sanitizer — which inflates each frame ~2–3× — even 256
  heavy schema / mutation frames approach that smaller budget. Raising the global default would turn a
  fail-closed guard into a stack overflow there. The empirical boundaries are encoded in the
  depth-safety tests, which pin the mutation check to the main actor for exactly this reason.

If a workload genuinely needs deeper schema validation or mutation on a known-large stack, the safe
shape is a per-call depth argument (as `SchemaValidator` already accepts internally, and Codable
exposes through `maxDecodingDepth`), not a higher global constant — so a small-stack caller stays
protected by default.

### Why some recursion is kept (guarded) rather than rewritten iteratively

The parser, lazy navigation, SAX readers, `JSONValue` build/serialize/equality, and JSONPath descent
are all iterative. The remaining recursive paths are kept recursive *on purpose*, because each is
already overflow-safe and an explicit-stack rewrite would cost clarity for no safety gain:

- **JSON Merge Patch** recurses on the *patch* object's nesting, and past its cap degrades to a
  whole-object replace — so it cannot overflow regardless of input.
- **JSON Patch / value mutation** recurses along the *pointer path*, whose depth is the number of
  path tokens (a finite, caller-supplied string), not the data depth — bounded and tiny in practice.
- **Schema validation** is the only one that recurses on data depth; it fails closed at its cap by
  recording a `ValidationError`. Its many-branch structure makes an iterative rewrite the riskiest
  for the least benefit, so it stays guarded.

Codable encode/decode recursion is mandated by the `Codable` protocol and cannot be removed at all;
it is bounded by the encode/decode caps above. New engine code is written iteratively from the start.

## Recommendations

- **Untrusted input?** Keep ``/AemiJSONCore/JSONParseOptions/maxDepth`` modest *if you will decode, encode, or
  schema-validate it* (all recursive). For pure parse / lazy / SAX / JSONPath workloads you can
  raise it freely — those never touch the call stack.
- **Decoding legitimately deep data?** The default ``AemiJSON/JSONDecoder/maxDecodingDepth`` (64) is
  safe on a 512 KiB worker or actor thread. Raise it only on a thread with a known large stack, such
  as the ~8 MB main thread.
- **Very deep documents?** Use the lazy ``/AemiJSONCore/JSON`` view or ``/AemiJSONCore/JSONEventReader`` / ``/AemiJSONCore/JSONEventStreamReader``
  rather than materializing a ``/AemiJSONCore/JSONValue`` (whose deallocation recurses).
- **Always treat decode as fallible** at the boundary: catch `DecodingError`, never `try!`. A guarded
  throw is recoverable; a stack overflow is not.

See <doc:Architecture> for why the engine is iterative throughout.
