# Querying and Mutation

Address, search, and transform JSON with the standard pointer, path, and patch formats.

## JSON Pointer (RFC 6901)

A ``JSONPointer`` addresses one location. Resolve it against a lazy ``JSON``…

```swift
let title = doc.root[pointer: "/store/book/0/title"].string
```

…or against a ``JSONValue``:

```swift
let value = JSONValue(doc.root)
let found = value.value(at: try JSONPointer("/store/book/0/title"))
```

Pointer parsing throws a typed ``JSONPointerError``. Array-index tokens follow RFC 6901 §4
exactly (`0` or `[1-9][0-9]*`; no leading `+`, sign, or zero-padding).

## JSONPath (RFC 9535)

A ``JSONPath`` is compiled once to an AST and returns a nodelist in document order.

```swift
let titles = try doc.root.query("$.store.book[?(@.price < 10)].title")
```

Supported: root `$`, child and descendant (`..`) segments; name, wildcard `*`, index
(including negative), slice `start:end:step`, and filter `?(…)` selectors; filter logic
`&&`/`||`/`!` with parentheses; comparisons against literals and relative/absolute queries;
existence tests; and `length()`, `count()`, `match()`, `search()`. The parser bounds nesting
depth to reject pathological expressions. It currently passes ~88% of the JSONPath Compliance
Test Suite; `value()`, full I-Regexp semantics, and the formal well-typedness checker are not
yet implemented. Parse errors are typed ``JSONPathError``.

## JSON Patch (RFC 6902)

A ``JSONPatch`` is an ordered sequence of `add` / `remove` / `replace` / `move` / `copy` /
`test` operations applied to a ``JSONValue``.

```swift
let patch  = try JSONPatch(patchData)              // from a JSON array of ops
let result = try patch.apply(to: JSONValue(parsing: targetData))
// or, bytes in / bytes out:
let out = try JSONPatch(patchData).apply(toData: targetData)
```

`move` into one's own child is rejected per §4.4, and `test` failures throw — all via the
typed ``JSONPatchError``.

## JSON Merge Patch (RFC 7396)

``JSONMergePatch`` recursively merges an object patch into a target; a `null` member removes a
key; a non-object patch replaces outright.

```swift
let merged = JSONMergePatch.apply(patch, to: target)        // JSONValue
let out    = try JSONMergePatch.apply(patchData, toData: targetData)
```

## Relative JSON Pointer

``RelativeJSONPointer`` ascends a number of levels (with an optional `+N`/`-N` index
adjustment) and then either yields the key/index name (`#`) or follows a JSON Pointer,
resolved from a base location.

```swift
let rel = try RelativeJSONPointer("1/sibling")
let value = try rel.resolve(from: base, in: document)
```

## Layering

JSON Pointer access, the ``JSONValue`` mutation primitives, and ``JSONPatchError`` live
together in the query/addressing layer, separate from the value model — so the data type stays
pure data plus (de)serialization. See <doc:Architecture>.
