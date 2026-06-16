# Async Streaming

Decode a JSON document incrementally from any asynchronous byte stream, without holding it whole in
memory.

## Overview

``JSONEventAsyncSequence`` adapts the resumable push reader (``JSONEventStreamReader``) to Swift
concurrency: give it any `AsyncSequence` whose element is `UInt8` and consume the document as a stream
of ``JSONEvent``s with `for try await`. It is Foundation-free and adds no dependency —
`URLSession.AsyncBytes` and `FileHandle.AsyncBytes` are already `AsyncSequence<UInt8>`, so they
compose directly.

```swift
import ADJSONCore

let (bytes, _) = try await URLSession.shared.bytes(from: url)
for try await event in JSONEventAsyncSequence(bytes) {
    switch event {
    case .key(let name): enterMember(name)
    case .string(let value): record(value)
    case .number(let value): record(value)
    case .bool, .null, .beginObject, .endObject, .beginArray, .endArray: break
    }
}
```

## Choosing a source

Any `AsyncSequence<UInt8>` works:

- `URLSession.AsyncBytes` — process a response body as it arrives over the network.
- `FileHandle.AsyncBytes` — stream a large file from disk without reading it all in.
- a custom `AsyncStream<UInt8>` you produce yourself.

## Events

Each ``JSONEvent`` marks one structural step of the document, in document order:

| Event | Meaning |
|---|---|
| `.beginObject` / `.endObject` | object braces |
| `.beginArray` / `.endArray` | array brackets |
| `.key(String)` | the next member's name |
| `.string` / `.number` / `.bool` / `.null` | a scalar value |

## Tuning and limits

- **`chunkSize`** (default 16 KiB) is how many bytes are pulled before each internal `feed`. Larger
  amortizes per-feed overhead; smaller lowers latency to the first event.
- **Depth** is bounded by ``JSONParseOptions/maxDepth``, not the call stack — the reader is iterative,
  so a pathologically nested document fails closed with ``JSONError`` instead of overflowing.
- **Profiles** apply: pass `options: .json5` or `.lenient` to stream relaxed input (see
  <doc:JSON5AndLenient>). The reader is fully resumable, so a token split across a chunk boundary —
  even mid-escape or mid-number — is held until the rest of its bytes arrive.
- **Back-pressure** is natural: the iterator pulls the next chunk only when you ask for the next
  event, so a slow consumer throttles the source.

## Completion and errors

When the source is exhausted, the sequence flushes the reader, which validates that the document is
complete — a truncated document throws ``JSONError``. A malformed token throws at the point it is
read. Treat the loop as `try`.

## Topics

- ``JSONEventAsyncSequence``
- ``JSONEventStreamReader``
- ``JSONEventReader``
- ``JSONEvent``
