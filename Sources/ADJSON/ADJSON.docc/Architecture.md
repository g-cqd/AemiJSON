# Architecture and Design Decisions

How ADJSON is built, and the reasoning behind the choices that shaped it.

## Two modules: a Foundation-free core

ADJSON ships as two layers. **`ADJSONCore`** is the engine — the tape parser, lazy ``JSON`` /
``JSONDocument`` / ``JSONValue``, and the query types (``JSONPath``, ``JSONPointer``,
``JSONPatch``, ``JSONMergePatch``) — and depends on **nothing**: no Foundation, no swift-syntax.
**`ADJSON`** is the umbrella that re-exports the core (`@_exported import`) and layers the `Data`
conveniences, the Codable coders, JSON Schema, and the `@JSONCodable` / `@Schemable` macros on top.

The split keeps Foundation at the boundary. The byte-scanning and encoding hot paths already
operate on `UnsafePointer<UInt8>` / `[UInt8]`, so the only Foundation type in the engine's public
API was `Data` — which moves to the umbrella as a thin overload (`parse(Array(data))`). The
Codable error types (`DecodingError` / `EncodingError`) are standard-library, not Foundation, so
the core's encode path keeps them without pulling Foundation in. A strict zero-dependency consumer
can therefore depend on `ADJSONCore` alone; everyone else uses `ADJSON` and sees the same flat API
as before. Internals that the umbrella's inlinable fast paths reach across the module boundary are
exposed with `package` (or `public`, where they are named by code that inlines into *your* module),
so the split is performance-neutral.

## The tape

`parse` scans the input **once** into a flat `[UInt64]` **tape**: a preorder flattening of the
document with one slot per value (and one per object key). There is no per-node heap
allocation and no object graph — just one contiguous integer array held inside an immutable
``JSONDocument`` alongside the original UTF-8 bytes.

Each 64-bit slot packs a tag and two payload fields:

```
bits 60..63  tag (null/bool/number/string/object/array)
bits 32..59  aux  (28 bits)
bits  0..31  low  (32 bits)
```

- **Scalars** (string/number/literal) store a byte `offset` (`low`) and a `length` plus a
  flag bit (`aux`): for strings, "contains an escape"; for numbers, "is an integer token".
- **Containers** (object/array) store their element `count` (`aux`) and the tape index
  **past their whole subtree** (`low`).

That last field is the key to laziness: skipping a value — or jumping to array element *k* — is
O(1) per step, because a container knows where its subtree ends without walking it.

### Why a tape (vs an object tree)

A `JSONSerialization`-style parser allocates a tree of `NSObject`/`Any` boxes; a `Codable`
decoder builds intermediate containers. Both pay allocation and ARC costs proportional to the
document, whether or not you read it all. The tape pays one array allocation and defers
everything else, which is what makes "parse a 1 MB payload, read two fields" cheap. The model
follows simdjson's On-Demand design and Foundation's own `JSONMap`.

### Limits encoded in the layout

Because `aux` is 28 bits and `low` is 32 bits, a single container holds at most 2^28−1
elements and the whole input is capped at 4 GiB. Exceeding either is rejected as
``JSONError/documentTooLarge`` rather than silently wrapping — a deliberate integrity guard.

## Lazy materialization

``JSON`` is a `struct` of `{ document, tapeIndex }`. Navigation moves the index along the
tape; typed accessors decode a Swift value from the borrowed bytes only when read. A missing
path is represented by a sentinel index, so `a.b.c.string` returns `nil` instead of trapping.

``JSONValue`` is the opposite end: a fully-materialized, mutable enum for editing and patching.
You opt into materialization explicitly by converting.

### Random access is linear — materialize once for repeated reads

The tape preserves member/element order rather than hashing it, so a single ``JSON`` key lookup
(`json["k"]`, `json.k`) or array index (`json[i]`) is an **O(n)** walk over that container's
children. Reading one or two fields out of a large object is exactly the cheap case the tape is
built for. But resolving *many* keys against the same object — or repeatedly indexing the same
array — is O(n·k); for that pattern, materialize the container once with ``JSON/object`` /
``JSON/array`` (each O(n), then O(1) per key/index against the returned `Dictionary`/`Array`) and
read from the result. No secondary hash index is kept on the lazy view: it would cost every parse
to benefit only the repeated-random-access minority, against a design whose whole point is to
defer work you may never do.

## Single-pass, recursion-free scanner

The scanner is iterative: an explicit heap stack of open containers replaces recursive
descent, so arbitrarily deep input costs heap (O(depth)) instead of call-stack frames and can
never overflow the stack. Nesting is additionally bounded by ``JSONParseOptions`` (`maxDepth`,
default 512). The same recursion-free posture is applied to the other depth-sensitive paths
(schema compilation, structural equality, JSONPath descent).

Strict mode enforces the RFC 8259 number grammar, validates string escapes, and checks RFC
3629 UTF-8 well-formedness (rejecting overlongs, surrogates, and code points above U+10FFFF)
inline, in the same pass. Duplicate-key detection (the I-JSON profile) buckets keys by an
FNV-1a hash to stay O(1) expected rather than O(n²), so a hostile object can't force quadratic
work.

## Typed throws

The parse layer and the single-domain query/schema entry points use Swift's typed throws
(`throws(JSONError)`, `throws(JSONPointerError)`, `throws(JSONPathError)`,
`throws(JSONPatchError)`), so callers can exhaustively handle a precise error type. Paths that
genuinely span domains (e.g. parse-then-patch-then-encode) stay untyped, and the Codable
surface uses Foundation's `DecodingError`/`EncodingError` as required by the protocols.

## Concurrency model

A ``JSONDocument`` is an immutable `final class` and `Sendable`: once parsed it can be shared
across tasks and actors with no synchronization. `ADJSON.decodeArrayConcurrently`
exploits this — it scans once, then hands disjoint element ranges to a task group; each worker
binds **its own** base pointer over the shared read-only storage, so there is no shared mutable
state and the work is data-race free under Swift 6's strict checking. Process-wide
``ADJSON/Metrics`` use `Atomic` from the Synchronization framework; the encoder's scratch-buffer
pool uses `Mutex`.

## The `@JSONCodable` fast path

Codable's container protocols are general but costly: existential containers, per-field
`String` keys, and dynamic dispatch. ``JSONCodable()`` generates, at compile time, a monomorphic
reader/writer for a `struct` that the coders dispatch to automatically. Decoding matches each
field's statically-known key against tape bytes (no `String` allocation) and skips unread
subtrees; encoding writes into a value-type buffer that inlines into your module. Conditional
conformances make `[T]`, `T?`, and `[String: T]` fast when `T` is, so collections and nested
fields benefit without per-element boxing. The type keeps standard `Codable` as a fallback, so
adoption is incremental and never a correctness risk.

## Safety and the memory model

The scanner and Codable decoder use `UnsafePointer` over the document's contiguous, immutable
storage for speed. The lifetime invariant — pointers are borrowed only inside a
`withBuffers`/`withBytePointer` scope while the owning ``JSONDocument`` is retained — is
documented at each boundary, and every tape and byte access in the decode path is
bounds-checked under `assert` (debug/test builds trap on any out-of-range index; release keeps
raw-pointer speed). The tape itself is a `ContiguousArray<UInt64>` to guarantee contiguous
storage.

### Why not `Span` / `UTF8Span` yet

`Span`/`RawSpan` are not used on the decode path because Codable's `Decoder` must be
`Escapable` — a `Span` cannot be stored in the shared decode context — and the current
toolchain's lifetime-dependence support can't yet thread spans through it. The single-pass
scanner is also blocked: storing a `Span` as a struct stored property currently requires the
experimental `LifetimeDependence` feature. `UTF8Span` would force a separate validation pass
over the bytes, defeating the single-pass design. These remain deferred deliberately, with the
unsafe surface kept small and `assert`-guarded in the meantime.
