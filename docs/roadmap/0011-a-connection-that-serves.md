---
status: done
blocked-by: []
date: 2026-11-15
---

# 0011 — A connection that serves: requests admitted in order, what cannot be read answered

From ask's `ask serve` (its ADR-0153), the first consumer to use `JSONRPCConnection` in the server's role. A probe there, three
requests in one write to a server that answers nothing before `initialize`, came back with the request sent after `initialize`
refused as "before initialize", and a line that was not JSON got no answer at all.

- **Order.** Each request from the peer is answered in a child task (roadmap 0006), which is right for the work and wrong for the
  decision: tasks start in any order, so a server cannot know which request came first. A protocol whose requests depend on one
  another needs that: nothing before `initialize`; a cancellation, which is a notification and so already in order, after the
  request it cancels has been taken.
- **What cannot be read.** A body that is not a message was dropped, and so was a line longer than the limit. A client is right to
  say nothing (a server's output may hold a log line). A server is asked by JSON-RPC 2.0 to answer: -32700 for what is not JSON,
  -32600 for what is not a request, under the id when one could be read.

## Done

`JSONRPCConnection(serving:framing:cancellation:admit:onNotification:)`. `admit` is called on the reader for each request, in
the order they arrive and before the next message is read, and returns the work that answers it, which runs in a child task as
before. Such a connection answers an invalid body with `JSONRPCMessage.Invalid`'s response, and a line that was too long with a
parse error, then reads on. The existing initializer and everything it does are unchanged: a connection made with it still says
nothing of what it cannot read.

Seven tests (`JSONRPCServingConnectionTests`), red first (the initializer did not exist): 200 requests admitted in the order sent;
what one admission changes is seen by the next; work that waits does not hold the reader; the three refusals, over lines and over
Content-Length; a client's silence. Broken on purpose twice: admission moved into the child task and the refusals reversed (five
tests red), and the work awaited on the reader (the waiting test hits its time limit).

Not done: the line limit of a connection is `LineFraming`'s default (8 MiB) and cannot be set; a Content-Length frame that breaks
still closes the connection, served or not.
