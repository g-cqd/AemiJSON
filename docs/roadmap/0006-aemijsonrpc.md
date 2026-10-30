---
status: done
blocked-by: []
date: 2026-10-30
---

# 0006 — `AemiJSONRPC`: JSON-RPC 2.0 framing and connections

analyzerkit P3, from the swift-search extraction. A product beside `AemiJSON`:

- **Framing.** Content-Length headers (LSP base protocol) with a header limit (8 KiB) and a body limit, case-insensitive header names,
  other headers ignored; newline-delimited messages (MCP stdio) with a line limit. Both find their delimiters with
  `AemiKernels.firstIndexOfByte` over the buffer, not byte by byte, and compact the buffer amortized.
- **Messages.** `JSONRPCID` (integer or string), request, notification, response, error (with the reserved codes), parsed from `JSON` and
  written with `JSONValue`.
- **Connection.** Requests matched to responses by id, any number in flight, a deadline per request, cancellation (a cancelled task sends
  `$/cancelRequest` when the peer speaks LSP), requests from the peer answered by a handler (default: a null result) so the peer never waits,
  notifications to a handler, a closed connection failing every waiter at once. Transport-agnostic: a sink to write, bytes fed in.
- **Stdio reading** in 64 KiB blocks (swift-search H8).

Ported from swift-search `LSPFrame`, `LSPFrameDecoder`, `LanguageServerConnection`, `MCPStdio`, with their tests first. Consumers: swift-search,
arcleak (`LspServer.swift`), ask (`AskMCP`), Atelier (`AtelierLSP/JSONRPC.swift`); each migrates in its own entry.

Red: framing split at every byte offset of a two-message stream, limits, a missing or malformed Content-Length, CRLF and LF lines, a response
for an unknown id, deadlines, cancellation, a peer request answered, close failing the waiters. Bar: framing a 1 MiB message at memchr speed
(≥ 5 GB/s on the header scan).

## Done

Product `AemiJSONRPC` (`Sources/AemiJSONRPC`), depending on `AemiJSONCore`, swift-collections' `OrderedCollections`, `AemiKernels` and
aemi's `AemiRuntime`, built with strict memory safety. 44 tests in `Tests/AemiJSONRPCTests`; the whole package passes (459 + 44 + 2).

- **`Framing.swift`.** `ContentLengthFraming` finds each CR of a header with `memchr` and resumes where the last search stopped, so a header
  cut into many chunks is scanned once; a body whose header has been read is never scanned, only copied. Header parsing is byte-level:
  `Content-Length` in any case, other headers skipped, at most 18 digits, limits of 8 KiB (header) and 64 MiB (body), then `headerTooLong`,
  `missingContentLength` or `contentTooLong(n)`. `LineFraming` scans only the new bytes, drops a CR before LF, skips blank lines, and reports
  an overlong line once as `.tooLong`, drops it up to its newline and goes on (ask's `LineSplitter` refuses everything after one, which
  leaves the caller no choice).
- **`Message.swift`.** `JSONRPCID`, `JSONRPCError` with the reserved codes, `JSONRPCRequest`, `JSONRPCNotification`, `JSONRPCMessage`
  parsed from bytes (`params` is a lazy `JSON` over the message's document), and `JSONRPC` writers that emit members in the order
  `jsonrpc`, `id`, `method`, `result`/`error`, `params`.
- **`Connection.swift`.** `JSONRPCConnection` over a `JSONRPCSink`: ids from 1, any number in flight, each request raced against its
  deadline in a task group, an abandoned request (deadline or cancelled caller) forgotten so its late answer is dropped, and the peer told
  through a `JSONRPCCancellation` (`.languageServer`: `$/cancelRequest`; `.modelContextProtocol`: `notifications/cancelled`). Peer requests
  are answered in child tasks by `onRequest` (default a null result); notifications go to `onNotification` in order on the reader. When the
  output ends or a frame breaks, every waiter and every later request fails with `closed(reason:)`; `waitUntilClosed()` returns then.
- **`FileDescriptorChunks.swift`.** A descriptor read in 64 KiB blocks on a `BlockingOffloadPool`, retrying `EINTR`: one `read` per block,
  where swift-search's `MCPStdio` makes one call per byte (its H8).

### Departures from the red commit

- Parsing throws `JSONRPCMessage.Invalid` (the error and the id, when one could be read, plus `response()` to answer it), not a bare
  `JSONRPCError` with the id hidden in `data`.
- The writers `throw`: `JSONValue.encodedBytes()` refuses NaN and the infinities, and a JSON-RPC body must not hide that.
- Two tests framed lines with a Content-Length peer; they waited forever. The connection suite now has a one-minute limit, so a lost
  continuation fails by name instead of hanging the run.

### Numbers

Release probe (`/tmp/rpcprobe`, best of 30–50, loaded machine, two runs):

| case | throughput |
|---|---|
| Content-Length, 1 MiB body in 64 KiB chunks | 15.2–15.5 GB/s |
| Header scan, 1,000 frames with 7 KiB headers | 5.8–6.1 GB/s (0.96 before `contentLength` used `memchr` per line) |
| Lines, 1 MiB line in 64 KiB chunks | 10.3–12.2 GB/s |
| Lines, 10,000 lines of 100 bytes | 1.5–1.7 GB/s, 15–17 M lines/s |

The bar (≥ 5 GB/s on the header scan) is met.

### Not done

- ask's single watchdog timer per connection (its roadmap 0114) and an injectable clock: every request still sleeps in its own child task.
  It works and the tests are deterministic, but a server with thousands of requests in flight pays a task each.
- Linux: `FileDescriptorChunks` imports Glibc and Musl but has not been built there.
- An outbox that orders writes: the sink must not interleave concurrent writes, and that is the sink's job for now.
- The consumers' migrations, each its own entry: swift-search (replaces `LSPFrame`, `LSPFrameDecoder`, `LanguageServerConnection` and
  `MCPStdio`, fixing H8), arcleak `LspServer.swift`, ask `AskMCP` (keeps its watchdog until this has one), Atelier `AtelierLSP/JSONRPC.swift`.
