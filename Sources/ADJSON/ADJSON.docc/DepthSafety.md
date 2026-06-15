# Depth Safety and Stack Exhaustion

How ADJSON handles deeply nested input — a small payload (`[[[…]]]`) that tries to exhaust the call
stack (CWE-674, a recursion DoS) — and why it goes far past Foundation's hard cap.

## The short version

A *recursive-descent* JSON parser pushes one (or more) call frames per nesting level, so a tiny
input of a few thousand `[` can overflow the thread stack and crash the process with an uncatchable
signal. Foundation defuses this in its **scanner** with a hard cap: a document nested deeper than
**512** throws `DecodingError.dataCorrupted` ("Too many nested arrays or dictionaries"). But the
*decoder* layer above it has no such guard — a `Decodable` that recurses through
`singleValueContainer` (adding no JSON structure) overflows at ~12k–19k levels.

ADJSON is built the opposite way: the **parser is iterative** (an explicit heap stack, not call
frames), so nesting costs heap, not stack. With ``JSONParseOptions/maxDepth`` raised, parsing, lazy
navigation, SAX reading, and JSONPath descent all handle **1,000,000+** levels with no overflow —
roughly 2000× Foundation's cap. The only stack-using consumer is the Codable decoder (the protocol
mandates recursion), and it is bounded by an explicit guard that **throws instead of crashing**.

## Which paths use the stack?

| Path | Strategy | Deep-input behavior |
|---|---|---|
| Tape parse (``ADJSON/parse(_:options:)-(_,_)``) | **iterative** | survives any depth up to `maxDepth`; then throws `.depthExceeded` |
| Lazy navigation (`json.a.b…`) | **iterative** | O(1) per step, no recursion |
| SAX (``JSONEventReader`` / ``JSONEventStreamReader``) | **iterative** | survives any depth |
| JSONPath `..` descent | **iterative** | survives any depth |
| ``JSONValue`` materialize (``JSONValue/init(_:)``) | **iterative** build | builds any depth; but see *tree deallocation* below |
| ``JSONValue`` serialize (``JSONValue/encodedBytes(options:)``) | **iterative** | serializes any holdable tree |
| ``JSONValue`` equality (`==`) | **iterative** | compares any depth (an explicit work-stack) |
| **Codable decode** (``ADJSON/JSONDecoder``) | recursive (protocol) | **throws** past `maxDecodingDepth` (default 2048) |
| JSON Schema validate | recursive | bounded by `maxDepth` (keep it modest for untrusted deep input) |

### Tree deallocation is the one inherent limit

Building a ``JSONValue`` is iterative, but the resulting value tree — like *any* recursive Swift
value type, and like Foundation's decoded `[Any]` / `NSDictionary` graphs — is **released
recursively** by ARC. Holding a tree deeper than ~30–40k levels (less on a small-stack worker
thread) and letting it deallocate overflows the stack. The fix is structural, not a bug to patch:
process very deep documents through the **lazy ``JSON`` view or the SAX readers**, which never
materialize a tree, or bound input depth. Dismantling a deep tree by walking it down a level at a
time (as opposed to a single bulk release) also avoids the recursion.

## The decoder guard

The Codable path is unavoidably recursive (each `init(from:)` decodes its children). ADJSON caps
that native recursion with ``ADJSON/JSONDecoder/maxDecodingDepth`` (default **2048**), independent of
`maxDepth`: past it, decoding throws a catchable `DecodingError` rather than overflowing. So you can
raise `maxDepth` to *parse / navigate* very deep documents iteratively, while a deeply nested (or
self-referential) `Decodable` still **fails closed**.

The default is chosen empirically: the heaviest path (keyed-object decode) overflows the ~8 MB main
thread around ~3.8k levels in a *debug* build (release reaches ~8k–14k), so the guard sits safely
below that — 4× past Foundation's hard 512, yet guaranteed to throw before the stack runs out in
both build modes. Raise it (to ~3000 on the main thread, more on a large stack) for legitimately deep
data; lower it on a small-stack worker thread (default ~512 KB → ~16× shallower).

```swift
var decoder = ADJSON.JSONDecoder()
decoder.options = JSONParseOptions(maxDepth: 100_000)  // iterative parser accepts deep input
decoder.maxDecodingDepth = 256                          // but cap the recursive decode (lower on small stacks)
// A 100k-deep document now throws DecodingError instead of crashing.
```

## Recommendations

- **Untrusted input?** Keep ``JSONParseOptions/maxDepth`` modest *if you will decode or
  schema-validate it* (both are recursive). For pure parse / lazy / SAX / JSONPath workloads you can
  raise it freely — those never touch the call stack.
- **Decoding on a worker thread** (default stack ~512 KB, ~16× smaller than the 8 MB main thread)?
  Lower ``ADJSON/JSONDecoder/maxDecodingDepth`` accordingly, or decode on a thread with a known large
  stack.
- **Very deep documents?** Use the lazy ``JSON`` view or ``JSONEventReader`` / ``JSONEventStreamReader``
  rather than materializing a ``JSONValue`` (whose deallocation recurses).
- **Always treat decode as fallible** at the boundary: catch `DecodingError`, never `try!`. A guarded
  throw is recoverable; a stack overflow is not.

See <doc:Architecture> for why the engine is iterative throughout.
