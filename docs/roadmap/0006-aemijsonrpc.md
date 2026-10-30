---
status: not-started
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
