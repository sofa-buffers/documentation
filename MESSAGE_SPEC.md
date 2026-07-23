# SofaBuffers Message & Marshalling Specification

> The "Marshall Plan": which wire primitive each schema type lowers to, and how
> composite/nested structures are laid out. **Bit-level encoding is not repeated
> here** — see [`CORELIB_PLAN.md`](./CORELIB_PLAN.md) §4 for field headers,
> varints, zig-zag, the `fixlen_word`, and the eight wire types. This document is
> the layer above: schema types → wire structure.

## 0. Scope & layering

```
YAML message definition  ──(this document)──▶  wire structure (CORELIB_PLAN §4)
   (validated by sofabuffers-schema-v1.json)
```

The corelib knows only the eight wire types (CORELIB_PLAN §4.3); it has no notion
of struct, union, enum, bitfield, or "array of structs". Those are schema
concepts that the generated code lowers to wire primitives. Several schema types
share one wire encoding — a struct and a union are both **sequences**; an enum and
a signed int both use the **signed-integer** wire type — and the schema is what
disambiguates them. Defining that lowering is the whole job of this document.

The *authoring* format itself (field attributes, enum/bitfield/union definitions)
and the *validation contract* live in the generator's
[`schema/README.md`](https://github.com/sofa-buffers/generator/blob/main/schema/README.md);
the wire bytes live in [`CORELIB_PLAN.md`](./CORELIB_PLAN.md).

Notation in the layout sketches (read **left to right = wire order**):

- `[id:type] name` — one field. The header comes first (its `id` and wire `type`;
  CORELIB_PLAN §4.3), then its payload. The trailing lowercase `name` is the schema
  field name, shown only for readability — **names are never on the wire**.
- `seq[id]( … )` — a sequence opened by a field with that `id`; `…` are its child
  fields; the closing `)` stands for its sequence-end marker (CORELIB_PLAN §4.9).

So `[0:i32] x` is "field id 0, type i32 (the struct field called `x`)". The exact
header and marker bytes are never spelled out here — that's CORELIB_PLAN's job.

---

## 1. Leaf (scalar) types → wire

| YAML `type` | Wire type (CORELIB_PLAN) | Notes |
|-------------|--------------------------|-------|
| `u8` `u16` `u32` `u64` | unsigned integer (§4.4) | declared width is a **storage hint**; the wire carries a single unsigned integer regardless |
| `i8` `i16` `i32` `i64` | signed integer (§4.5) | zig-zag |
| `boolean` | unsigned integer (§4.4) | no own wire type; encoded as `0`/`1` via the corelib bool helper |
| `enum` | signed integer (§4.5) | no own wire type; carries the member's value, signed 32-bit range |
| `bitfield` | unsigned integer (§4.4) | no own wire type; flags packed by generated code at their `pos` bits |
| `fp32` | fixlen, subtype fp32 (§4.6) | |
| `fp64` | fixlen, subtype fp64 (§4.6) | |
| `string` | fixlen, subtype string (§4.6) | UTF-8, no null terminator |
| `blob` | fixlen, subtype blob (§4.6) | opaque bytes |

**Schema attributes that never reach the wire:** `decimals`, `unit`,
`description`, `deprecated` (docs/tooling hints), and `maxlen` (a **normative
validity bound** on string/blob byte length — §7).

Not reaching the wire is not the same as not binding it: `maxlen` — like an array's
`count` (§3) — is **not encoded**, but it **does constrain what is valid**. A
`string`/`blob` longer than its `maxlen` is malformed input, exactly as an array
element count over its `count` is (§7).

---

## 2. Defaults, omission, and empty-vs-absent

A **message-layer** rule; the wire spec is deliberately unaware of it (CORELIB_PLAN
§4.7 states only neutral wire mechanics).

- **Init to defaults.** A new message has every field at its schema `default` (or
  the type's zero value when none is given; a union uses `default_id`).
- **Sparse encoding (mandatory, canonical).** The encoder **MUST** emit a field
  **iff its value ≠ its default**; an omitted field is reconstructed as the
  default. (A `u8` left at default `7` never appears on the wire.) There is **no
  dense mode** — so every message value has exactly **one** canonical encoding.
  (The same principle reaches the byte level: every varint is emitted in its
  minimal form, and a decoder accepts-and-normalizes a non-minimal one —
  CORELIB_PLAN §4.1.)
- **The ≠-default test is per field — except for a `sequence`.** A `sequence`
  (a `struct` or `union`, and the wrapper form of a composite/dynamic-element
  array — §5, §6) is **never omitted as a whole**. It is **always framed** with
  `sequence_begin`/`sequence_end`, and the ≠-default test is applied
  **recursively to its child fields**. A nested object all of whose fields equal
  their default is therefore emitted as an **empty wrapper sequence** (the two
  bytes `sequence_begin(id)` + `sequence_end`), **not** dropped. *Rationale:* a
  whole-object comparison would depend on struct padding and in-memory layout and
  could not be reproduced identically across languages; a per-field rule is
  portable and keeps the encoding canonical.
- **Sparse omission reaches into wrapper-array elements (leaf elements only).**
  A wrapper-sequence array (§5) *is* a sequence and its elements *are* its child
  fields (`id = index`, §5.1), so the per-field rule above applies to them with no
  new machinery:
  - a **`string`/`blob` element is a leaf field**, so it **MUST be omitted iff it
    equals its element default**. The encoder drops it; the decoder restores the
    missing `dest[id]` from the element default. This is the only place an array
    element leaves an id **gap** on the wire. (A decoder still accepts a present,
    default-valued element for robustness, but a conformant encoder never emits
    one — so the encoding stays canonical.)
  - a **`struct`/`union`/nested-array element is itself a sequence**, so the
    carve-out above governs it: **always framed, never omitted**, even when all its
    fields equal their defaults; its interior follows the per-field rule
    recursively. (One exception: in a **fixed-count** array the *trailing* run of
    default elements is elided even for sequence-form elements — §3, §5.1.)

  A wrapper array is therefore, on the wire, **indistinguishable from a struct
  whose default-valued fields are omitted** — it is the same rule, not an analogy.
  **Scope:** this reaches *only* sequence-form arrays (§5). The compact scalar
  arrays of §3 are serialized linearly and gap-free — their elements carry no
  `(id, type)` header, so per-element id-gap omission never applies to them
  (their only compaction is the trailing-default run of a fixed-count array, §3).
- **No presence / is-set bit** (proto3-style). The application gives the zero
  value meaning where needed — e.g. a command enum with `NONE = 0` whose handler
  does nothing.
- **Empty ≠ absent — at the *array* level.** The wire can now carry an explicit
  empty array and an empty sequence (CORELIB_PLAN §4.7, §4.9), so:
  - *absent* → reconstructed as the default (which may be non-empty, e.g.
    `default: [3, 4]`);
  - *explicit empty* → the empty collection, overriding a non-empty default.
    (A **fixed-count** array has no empty value — it always has `N` logical
    elements — so its explicit-empty wire form decodes to the `N`-element
    all-default value, overriding a non-default schema `default`; §3.)

  This is what enables a faithful JSON `[]` ↔ SofaBuffers round-trip.

  At the **element** level the sparse rule above gives the opposite: inside a
  wrapper array a default-valued `string`/`blob` element is **indistinguishable
  from an absent one** (both reconstruct to the element default). Trailing default
  elements therefore collapse — `["a", ""]` encodes exactly like `["a"]`, and an
  all-default array such as `["", ""]` encodes exactly like the empty wrapper `[]`.
  This is intentional and round-trips losslessly against a default-initialised
  destination (§5.1).

---

## 3. Scalar arrays (compact wire forms)

Arrays of **numeric primitives** use the dedicated array wire types
(CORELIB_PLAN §4.7–4.8) — a single count prefix replaces per-element headers,
which is what keeps them compact:

| `items.type` | Wire type |
|--------------|-----------|
| `u8`…`u64`   | array of unsigned integers (§4.7) |
| `i8`…`i64`   | array of signed integers (§4.7) |
| `fp32` `fp64`| array of fixlen values (§4.8) |
| `enum`       | array of **signed** integers (§4.7) — enum → signed integer |
| `boolean`    | array of **unsigned** integers (§4.7) — bool → `0`/`1` |
| `bitfield`   | array of **unsigned** integers (§4.7) — packed flag word per element |

`enum`, `boolean`, and `bitfield` arrays reuse the existing scalar array wire
types — they already lower to a single signed/unsigned int — so there is **no new
wire form** for them; only the schema must permit them as element types.

- `count` in the schema declares a **fixed-length** array of exactly N logical
  elements — **never on the wire**. The wire carries an element count `M`,
  `0 .. N` (CORELIB_PLAN §4.7), a *compaction* of the N-element value: the
  trailing run of default elements is elided (normative rule below); `M > N` is
  `INVALID` (§7). `count` is **optional**, exactly like `maxlen`: omit it for a
  dynamic/unbounded collection (heap targets); declare it for a fixed-length
  array — which is also what lets heap-less targets pre-size the buffer.
- A zero-length array is valid — an **explicit empty array**. Its exact wire form
  (including why an empty fixlen array still carries its `fixlen_word`) is
  byte-level encoding and lives in CORELIB_PLAN §4.7–4.8; all that matters at this
  layer is that an explicitly empty array **is representable** (§2).
- **No interior sparsity here.** A compact scalar array is serialized
  **linearly and gap-free**: the `M` elements named by the count prefix are all
  present, in order, with no per-element header — a default-valued element
  *before* the last non-default one stays on the wire. The only compaction is
  the **trailing**-default run of a fixed-count array (below); the id-gap
  omission of §2/§5.1 applies **only** to wrapper-sequence arrays
  (string/blob/struct/union elements), never to these count-prefixed forms.
  The array as a whole follows the ordinary ≠-default field test of §2.

**Fixed-count arrays — under-count is a trailing-default run (normative).**
A field declared `count: N` is a **fixed-length** array of exactly `N` logical
elements. Its wire count `M` **MUST** satisfy `0 ≤ M ≤ N`; `M > N` is the
`INVALID` decode outcome (§7). A wire count `M < N` denotes an array whose last
`N − M` elements equal the **element default** (the element type's default; its
zero value when none is defined) — a trailing-default run, elided for
compactness by the same sparse principle that omits a default-valued scalar
field (§2). A decoder **MUST** materialize exactly `N` elements — the `M` wire
elements at positions `[0, M)`, element defaults at `[M, N)` — **regardless of
its storage model**: a pre-sized fixed array and a growable list MUST both
recover the same `N`-element value, so the round-trip is identical across
implementations.

**Canonical encoding.** Whether the field appears at all is the ordinary
≠-default test of §2, applied to the full `N`-element value; a schema `default`
shorter than `N` (§6) stands for that default padded to `N` with element
defaults. When the field is emitted, the encoder **MUST** set `M` to one past
the index of the last element that differs from the element default, and MUST
NOT emit the trailing default run. `M = 0` — every element at the element
default, but the array as a whole differing from its (padded) schema
`default` — is the explicit empty array of §2, and decodes back to the
`N`-element all-default value. A decoder still accepts a non-canonical
encoding that carries trailing default elements; it decodes to the same
`N`-element value.

(For a **dynamic** array — no `count` — nothing changes: there is no `N` to
fill to, so a trailing default element is significant and stays on the wire,
and the wire count is simply the array's length.)

---

## 4. Sequences: the one composite primitive

Everything that is **not** a leaf or a scalar array is a **sequence**
(CORELIB_PLAN §4.9). A sequence opens a fresh ID scope; its schema role is known
only to the generated code. An **empty sequence** is legal and is the composite
counterpart of a zero-count array.

### 4.1 Struct — `type: struct`

A sequence whose children are its **named fields**, each with its own `id`.
Structs nest arbitrarily (a struct field of `type: struct` is just another
sequence), bounded by `MAX_DEPTH = 255`.

```
somestruct = seq[20](                  # wrapper id 20 = the struct field's id
  [0:u8] nestedint   [1:str] nestedstring
  seq[2]( [0:i32] deepint )             # nestedstruct — a nested sequence at id 2
)
```

### 4.2 Union — `type: union`

A sequence carrying **at most one** child: the present field, whose `id` selects
the active `oneof` option. `default_id` applies when none is set. Indistinguishable
on the wire from a one-field struct; the schema disambiguates. An empty union
sequence means "no option active" → `default_id`.

A union **option may be any field type** — a scalar, an array, a struct, even
another union — so a union models a tagged sum type with an arbitrary payload.
Nothing special on the wire: the active option is just its normal encoding,
placed as the single child.

```
someunion = seq[21]( [1:str] option2 )   # option2 (id 1) active; the id selects it
```

---

## 5. Nested & composite combinations

The single rule that covers every remaining case:

> **An array of composite (variable-size) elements is a *wrapper sequence* whose
> children are the elements, in order.** Each element is itself self-delimiting —
> a fixlen value (string/blob) or a nested sequence (struct / union / inner
> array) — so element boundaries are unambiguous.

Such a wrapper carries **no count field**: its elements are delimited by the
sequence end, in contrast to the compact scalar arrays of §3, which carry a count
prefix. (Both forms are "arrays"; they differ only in how the length is recovered —
a prefix count vs. a delimiter.)

Why a wrapper sequence and not "the same field id repeated" (protobuf `repeated`):
only the wrapper can represent an **explicit empty** array (an empty wrapper
sequence), staying consistent with the empty-array form (§2, §3).

### 5.1 Element identity inside an array wrapper (normative)

A wrapper sequence is an **ordinary sequence**, so **every element is a normal
field with its own `(id, type)` header** — one field header per element, from the
wrapper's `sequence start` to its sequence end. There is **no header-less element
form here**; the only header-less elements are the compact scalar arrays of §3,
which are a different wire type.

**Element id = the 0-based array index.** The first element has id `0`, the second
id `1`, and so on, so on the wire **id ≡ array index**. This keeps the ids unique
within the wrapper scope (the "unique ids per scope" rule holds, no exception), and
the generated code can place each element directly at `dest[id]` without a separate
counter. Elements appear in ascending index order, but the id sequence **may
contain gaps**: a `string`/`blob` element equal to its default is omitted (§2), so
ids such as `0, 2, 3` are well-formed — not an error. (Languages with 1-based
arrays, e.g. Lua, apply the +1 offset in their binding; the wire is always 0-based.)

Consequences:
- The element header grows with the id: small indices stay compact, larger ones
  cost an extra header byte or two (CORELIB_PLAN §4.3 for the header encoding). Only
  composite/sequence arrays pay this — the compact scalar arrays of §3 carry no
  per-element headers — and since composite elements are already framed, the growth
  is modest.
- Array length is bounded by `ID_MAX` (INT32_MAX), the same range as the schema
  `count`.

The wrapper sequence carries the array field's own `id` in its parent scope; an
empty wrapper (a sequence with no children) is the explicit empty array.

(Array-of-composite also requires no new decoder machinery in a corelib — an
implementation note in CORELIB_PLAN §4.9. The only bound relevant at this layer is
that skipping/nesting stays within `MAX_DEPTH = 255`.)

**Sparse elements & default reconstruction (normative).** A `string`/`blob`
element equal to its element default is **not** written (§2); its id is simply
absent from the wrapper (`struct`/`union`/nested-array elements are sequences and
are always present, so they never create a gap). Before applying a wrapper array a
decoder **MUST** initialise every destination slot to its element default — a
target pre-sized to the schema `count`/`maxlen` on heap-less profiles, or a fresh
buffer sized to the transmission — then write each present element at `dest[id]`,
leaving absent ids at their default. **Array length** is recovered as follows:
for a **fixed-count** array (`count: N`) it is **`N` for every target** — a
growable-list target MUST default-fill to `N` exactly like a pre-sized one
(§3, fixed-count rule), and an element id `≥ N` is `INVALID` (§7); for a
**dynamic** array (no `count`) it is *highest present id + 1*. Trailing default
*leaf* elements are therefore indistinguishable from a shorter wire form
(§2) — by design, and lossless against a default-initialised destination. A decoder
**MUST** accept these gaps; when the element type has no default, supplying a
cleanly initialised destination is the application's responsibility.

**Fixed-count wrapper arrays elide the trailing default run — sequence-form
elements included (normative).** The canonical-encoding rule of §3 applies to a
wrapper array with `count: N` unchanged: the encoder emits elements only at ids
`< M`, where `M` is one past the index of the last non-default element. Within
`[0, M)` the existing rules hold — a default `string`/`blob` element leaves an
id gap (§2); a sequence-form element is always framed. In the trailing run
`[M, N)`, however, the elision covers **sequence-form elements too**: a
trailing all-default `struct`/`union`/nested-array element — which at an
interior position would encode as an empty frame — is not written at all. This
is the one place a sequence element may be absent; the decoder recovers it by
the `N`-fill above, not as a gap. For a **dynamic** array trailing sequence
elements are **not** elided: with no `N` to fill to, the trailing empty frame
is exactly what distinguishes `[s, default]` from `[s]` on a growable target.

### 5.2 The cases

(`seq[k]` below is the array field itself, at its own id `k`; the children's ids
`0,1,…` are the array indices.)

| Case | Wire structure | Status |
|------|----------------|--------|
| **struct with arrays** | the struct is a sequence (§4.1); a child is a scalar array (§3) or array wrapper (below) | ✅ a struct field can be `type: array` |
| **array of strings/blobs** | `seq[k]( [0:str] [1:str] … )` — elements are fixlen values | ✅ schema routes string/blob items to a sequence |
| **array of structs** | `seq[k]( seq[0](fields…) seq[1](fields…) … )` | ✅ via recursive `items` (§6) |
| **array of unions** | `seq[k]( seq[0](option) seq[1](option) … )` | ✅ via recursive `items` |
| **array of arrays** | `seq[k]( [0:arr] [1:arr] … )` — each child is itself an array (a compact scalar array, or a wrapper if its elements are composite) | ✅ via recursive `items` |
| **map** = `array of struct{ key, value }` | `seq[k]( seq[0]([0:str] key  [1:u32] val) … )` | ✅ a pattern, not a distinct type |

Worked sketch — `points: array of struct{ x:i32, y:i32 }` (3 elements):

```
points = seq[5](                     # the array field, at its own id 5
  seq[0]( [0:i32] x  [1:i32] y )      # element 0 — wrapper-child id 0
  seq[1]( [0:i32] x  [1:i32] y )      # element 1 — wrapper-child id 1
  seq[2]( [0:i32] x  [1:i32] y )      # element 2 — wrapper-child id 2
)
# outer ids 0/1/2 = the array indices; inner ids 0/1 = the struct's own fields x/y
```

Worked byte example — a **sparse `string` element** (the issue-#6 case); byte
values are shown for illustration only (the encoding itself is CORELIB_PLAN §4's
job — normative *here* is only which elements are present vs. omitted). Array
`tags: array of string` at id `5`, element default `""`, value `["A", "", "C"]`;
element 1 equals the default and is therefore omitted:

```
5:seq          2E        sequence start, id 5   = (5<<3)|0b110
  0:str "A"    02 0A 41  elem id 0: header (0<<3)|2 ; fixlen_word (1<<3)|2 ; 'A'
  (1 omitted)            elem id 1 == default "" → not written
  2:str "C"    12 0A 43  elem id 2: header (2<<3)|2 ; fixlen_word (1<<3)|2 ; 'C'
  end          07        sequence end
```

→ `2E 02 0A 41 12 0A 43 07` (8 bytes). The decoder restores `dest[1] = ""` from the
element default; the recovered array is `["A", "", "C"]`.

Written densely instead (the pre-clarification behaviour), element 1's header plus
its empty `fixlen_word` — the two bytes **`0A 02`** — would sit between `41` and
`12`, giving `2E 02 0A 41 0A 02 12 0A 43 07` (10 bytes). That 2-byte-per-default
delta, present-but-empty vs. omitted, is exactly what issue #6 resolved: the sparse
form is now the single canonical encoding.

### 5.3 General recursion

Any element type composes the same way: encode the element exactly as it would be
as a standalone field (leaf, scalar array, or sequence) and place it as a child of
the array's wrapper sequence, at the child id equal to its array index (§5.1). Each
nesting level adds one sequence depth; the total stays within `MAX_DEPTH = 255`.
There is no special case beyond "leaf / scalar-array vs. sequence."

### 5.4 Maps and recursive types

**Map** — there is no distinct map type; a map is `array of struct{ key, value }`
(a wrapper sequence of two-field structs). Being a sequence-form array it carries
**no length field**: entries are delimited by the sequence end, each at
its index id (§5.1). Schema `count` follows the fixed-count rule (§3): a heap
target omits it for an unbounded map; a heap-less target declares it to
pre-size — and thereby gets a fixed-length array of exactly `N` entry structs,
absent entries decoding as all-default entries (the natural "empty slot"
sentinel for a fixed-capacity map). A length is still never baked into the
*wire*: entries remain end-delimited and the trailing default run is elided
(§5.1).

**Recursive types** — a struct may reference itself, directly or through an array
element, via a `$ref` to a predefined `$defs` struct. This expresses trees and
linked lists:

```
treenode = struct{ value: i32, children: array of <$ref treenode> }
```

On the wire this is nothing new — just nested sequences that bottom out when a
node's child array is empty or omitted. Three guardrails:

- **Decode is bounded.** `MAX_DEPTH = 255` (CORELIB_PLAN §4.9): a decoder rejects
  anything nested deeper, so a hostile or buggy stream cannot exhaust the stack.
- **Termination must be reachable.** Recursion has to pass through an
  optional / possibly-empty field (an array, or an omittable child) so a finite
  instance exists — an empty/absent child array is the natural base case. A struct
  that *required* a non-empty copy of itself could never be encoded.
- **Encode needs an acyclic graph.** Trees are acyclic by construction; if an
  application hands the encoder an object that points back to an ancestor (a real
  cycle), encoding would loop — the generated encoder should guard with the same
  `MAX_DEPTH` budget and error rather than spin.

Schema validation itself does **not** loop: a `$ref` in a message definition is an
opaque name the generator resolves, not a structure the validator expands, so
validating a recursive definition terminates immediately.

---

## 6. Schema implications

The wire model supports unbounded nesting; the YAML schema must be able to
**express and validate** it. The proposed extension to
`sofabuffers-schema-v1.json` makes the array element definition (`items`)
**recursive** — effectively a field definition without a schema `id` (the element's
wire id is its array index, §5.1) — so every type can be an array element:

- leaf elements: `u8…u64`, `i8…i64`, `fp32`/`fp64`, `string`, `blob`, **`enum`**,
  **`boolean`**, **`bitfield`** (the last three reuse the scalar array wire forms);
- composite elements: **`struct`** (`fields`), **`union`** (`oneof` / `default_id`),
  **`array`** (nested `items`) — the recursion that yields matrices, lists of
  records, and lists of variants;
- recursion via `$ref` to a predefined `$defs` struct/union (§5.4).

The schema requires the matching sub-definition per element type
(`struct → fields`, `union → oneof`, `array → items`, `enum → enum`,
`bitfield → bits`) and rejects mismatches (e.g. `maxlen` on a struct element, or
`fields` on a scalar). **The deeper the nesting allowed, the larger and more
conditional the schema — but it buys arbitrary composition under one uniform wire
rule (§5.3).**

Relaxations carried by the zero-length-array change:

- `items.count` is **optional** (like `maxlen`): present → the array is
  **fixed-length** with exactly `N` logical elements (§3) — the wire carries the
  compacted count `0 .. N`, decode fills back to `N`, and heap-less targets
  pre-size from it; omitted → dynamic/unbounded. It never appears on the wire.
- the array `default` may be **shorter than, or empty relative to,** `count`
  (`minItems` dropped; `maxItems ≤ count` kept), so an explicit `default: []` can
  override a non-empty default (§2). For a fixed-count array a shorter `default`
  stands for its `N`-element padding with element defaults (§3).

Deliberately left for later (cheap to add): deep `default`-value validation for
composite-element arrays (currently a generic array bounded by `count`).

---

## 7. Decode outcomes — what generated code must do

The three-valued decode outcome — `COMPLETE` / `INCOMPLETE` / `INVALID`, the rule
that `INCOMPLETE` is a first-class non-error, the precedence of `INVALID` over
`INCOMPLETE` when input is both malformed and truncated, and the no-finalize /
caller-owns-end-of-input contract — is the **corelib's API contract**, defined
normatively in [`CORELIB_PLAN.md`](./CORELIB_PLAN.md) §5.2 (error codes: §6.3).
This document adds only the obligations on **generated code**:

- **Return the corelib's status verbatim.** A generated `deserialize` / decoder
  `feed` neither invents a finalization gate nor downgrades `INCOMPLETE` into a
  `COMPLETE` or an `INVALID` on the caller's behalf. Whether a trailing
  `INCOMPLETE` is a truncation error is the *application's* framing decision,
  exactly as it is for direct corelib use.
- **Bind incrementally.** A generated decoder is driven by the corelib `feed` and
  binds each field the moment it completes, so an object larger than any buffer
  still assembles across chunk boundaries (CORELIB_PLAN §6.1).
- **Enforce schema bounds as `INVALID`.** The corelib cannot know the schema, so
  schema-bound violations are detected — and reported — by generated code: a wire
  element count `M > N` on a fixed-count array, a wrapper-array element id
  `≥ N` (§3, §5.1), or a `string`/`blob` whose wire byte length exceeds its schema
  `maxlen` (§2), is malformed input and **MUST** be reported as `INVALID`,
  the same terminal outcome as the corelib's own (CORELIB_PLAN §5.2) — never as
  `INCOMPLETE`, and never silently truncated to the bound.

### 7.1 A declared bound binds every target (normative)

A schema `count: N` on an array and a `maxlen: L` on a `string`/`blob` are
**wire-validity bounds**, not sizing hints. They bind **every implementation,
regardless of its allocation strategy**: a heap-less target that pre-sizes a buffer
from the bound and a heap target that allocates per message **MUST both reject**
input that exceeds it, with the same `INVALID` outcome.

A decoder **MUST NOT** accept an over-bound value merely because its storage happens
to be able to hold it. Whether the bound is enforced must not be an emergent property
of the memory model — two conformant implementations of the same schema **MUST** agree
on which messages are valid.

*(Rationale: a bound that only heap-less profiles honour is not a contract — it makes
the same bytes valid on one implementation and invalid on another, which is precisely
the silent interop failure a shared wire format exists to prevent. `count` already
binds every target for the analogous reason: §3, §5.1.)*

### 7.2 Omitting a bound declares an unbounded field (normative)

A `string`/`blob` without `maxlen`, or an array without `count`, is **unbounded**: the
receiver **MUST** materialize as much as the received message specifies. An unbounded
field has no schema bound to violate, so its length alone can never yield `INVALID` —
the format-wide ceilings of CORELIB_PLAN §6.2 still apply.

This form is available only to targets that allocate dynamically. A heap-less profile
requires the bound in order to pre-size, so a schema intended for one **MUST** declare
it.

Because an unbounded field lets the **sender** dictate the **receiver's** allocation,
an implementation may additionally be configured with generic, schema-independent
receiver limits — a **policy** mechanism deliberately distinct from schema-bound
validity. See CORELIB_PLAN §6.2.1.

### 7.3 A header wire type that contradicts the schema (normative)

Every declared type maps to exactly one wire type (§1); a `fixlen` type maps additionally
to exactly one subtype (`fp32`, `fp64`, `string`, `blob`). A field whose header carries a
different wire type — or, for `fixlen`, a different subtype — than the one its declared
type maps to **MUST** be **skipped**, exactly as a field with an unknown id is skipped
(CORELIB_PLAN §5.2). A decoder **MUST NOT** report such a field as `INVALID`, and **MUST
NOT** decode its payload into the declared field.

The check reaches exactly as far as the wire format distinguishes, and no further: `u8`,
`u16`, `u32`, `u64`, `boolean`, `enum` and `bitfield` all map to the unsigned-integer wire
type, so a header carrying that type is well-formed for every one of them. Value-range
conformance is not a wire-type question and is outside this clause.

*(Rationale: a decoder must already have a path for a field it cannot use — the unknown-id
skip. A field whose wire type contradicts the schema is the same situation, so it takes the
same path; reporting `INVALID` instead would create a second, divergent handling of "a
field this decoder cannot consume" where one is already specified. Because the mismatch is
detected against the schema, generated code is what detects it — the corelib is
schema-agnostic (§7). This clause nevertheless constrains the observable outcome, not which
layer produces it: an object-API profile that hands the schema to the corelib as a
descriptor table and checks there is equally conformant.)*

### 7.4 A field id repeated within one scope (normative)

Ids are unique within a sequence scope (CORELIB_PLAN §3), so an encoding that repeats one
is **not well-formed** and producers **MUST NOT** emit it. A decoder **MUST** nevertheless
process it deterministically, and **MUST NOT** report it as `INVALID`.

For each field id in a scope, the **last** occurrence applies. The rule binds **per field
id, not per sequence**: a sequence opened again **continues** its scope, because a sequence
opens an id scope *and nothing more* (CORELIB_PLAN §3) and so carries no value of its own.
Children set by an earlier opening whose ids do not recur in a later one **are retained**.
This covers structs (§4.1) and unions (§4.2).

An **array wrapper is the exception**: the wrapper *is* the value of its array field — that
is why arrays are carried in a wrapper rather than by repeating one id, and how an
explicitly empty array is represented (§5). A later occurrence therefore **replaces** the
array, discarding elements from earlier occurrences.

An occurrence skipped under §7.3 is **not** an occurrence for this clause: a correctly
typed earlier occurrence survives a mis-typed later one.

```
seq[10]( [3:blob] x )  seq[10]( [1:fp64] y )   →  nested{ bytes_field = x, f64 = y }
```

*(Rationale: "the last occurrence wins" is already the universal behaviour for a repeated
scalar; this clause extends the same rule to nested scopes by applying it where a value
actually lives — per field id within a scope, and to an array wrapper as a whole. Neither
case is `INVALID`, because rejecting a repeated id would oblige every decoder to track
which ids it has already seen at every level of nesting, up to `MAX_DEPTH`. The rule above
is the one a streaming decoder follows with no bookkeeping at all.)*

---

## 8. String validity: UTF-8

A `string` value is **UTF-8** (§1), length-framed on the wire — no other
encoding, no BOM, no terminator. `blob` (§1) is the type for opaque byte
sequences. That is the whole type distinction: `string` means *UTF-8 text*, and
producers — hand-written or generated — **MUST NOT** emit non-UTF-8 bytes in a
`string`; put arbitrary bytes in a `blob`.

**Representation is the language's business, not the format's.** A
byte-container string type (C `char[]`, C++ `std::string`, Go `string`, Zig
`[]const u8`) stores the wire bytes verbatim — no transcoding, zero-copy
allowed; interpreting code points (iterating, rendering, normalizing) is the
application's job, not SofaBuffers'. A Unicode string type (Java/C# `string`,
JavaScript strings, Python `str`, Rust `String`) transcodes at the boundary
using its **strict** converters.

**No silent replacement, ever (normative).** An implementation **MUST NOT**
substitute `U+FFFD` (or otherwise mutate, truncate, or empty) an invalid-UTF-8
`string`, in any mode, in either direction: invalid bytes are either preserved
verbatim (byte-container types, check OFF) or rejected. Lossy replacement is a
data mutation — it breaks the byte-exact round-trip the conformance vectors
require and silently rewrites payloads in any decode→re-encode relay.

**Embedded U+0000 is permitted** in a `string`: it is valid UTF-8 and the wire
is length-framed. Producers whose consumers use NUL-terminated conventions
SHOULD avoid embedded NUL or use `blob` (interop note in
[`CORELIB_PLAN.md`](./CORELIB_PLAN.md) §6.4).

Whether and when UTF-8 validity is *checked* — the **`SOFAB_STRICT_UTF8`**
option (byte-container targets; Unicode-string targets are always strict), its
**ON** default, its symmetric encode-and-decode enforcement (`INVALID` on
decode, `InvalidArgument` on encode), the pinned OFF behavior (*raw or reject,
never silent lossy*), the skip exemption (skipped fields are never validated —
wire validity of unread content is the producer's responsibility), cross-chunk
semantics, and the compile-out allowance for footprint profiles — is corelib
behavior, defined
normatively in [`CORELIB_PLAN.md`](./CORELIB_PLAN.md) §6.4. The option is a
**validation policy, never a wire-format switch**: it decides accept-vs-reject
and never changes how valid data is encoded, so peers with different settings
interoperate on all valid data. Conformance testing and the SofaBuffers
differential fuzzer run with the check **ON** — which is also the shipped
default — so cross-implementation interop requires it on.
