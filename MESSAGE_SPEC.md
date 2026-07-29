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
| `u8` `u16` `u32` `u64` | unsigned integer (§4.4) | one unsigned-integer wire type carries every width; the declared width is a **normative validity bound** on the value — a wire value outside its range is `INVALID` (§7.1) |
| `i8` `i16` `i32` `i64` | signed integer (§4.5) | zig-zag; the declared width is a **normative validity bound** — a wire value outside its range is `INVALID` (§7.1) |
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

**A scalar's declared width is a validity bound, not merely a storage hint.** The
integer scalars (`u8`…`u64`, `i8`…`i64`) share one unsigned/signed wire type
regardless of width (table above) — the width is **not** encoded — but it **does
constrain what is valid**, exactly as `count` (§3) and `maxlen` do. A wire value
outside the declared width's range — a `u8` carrying > 255, a `u16` > 65535, an
`i16` outside −32768 .. 32767, and so on — is malformed input and **MUST** be
reported `INVALID` (§7.1); a decoder **MUST NOT** mask it to the width (silent data
loss) nor keep the over-width value. An `enum` is bound the same way by its signed
32-bit range (table above). Because over-width is rejected, native-width storage is
always sufficient — the receiver never has to hold a value wider than the field's
declared type, which is the sense in which the width is also a *storage* fact.

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
- **The ≠-default test is per field — and a `sequence`-typed field is no
  exception.** A `sequence` (a `struct` or `union`, and the wrapper form of a
  composite/dynamic-element array — §5, §6) opens an id scope and *nothing more*
  (CORELIB_PLAN §3), so its value is compared **per child field, recursively** —
  never as a raw byte image:
  - a sequence-typed **field MUST be omitted iff its value equals the field's
    declared `default`**: for a `struct`, the value whose every child equals its
    own declared default; for a `union`, `default_id` carrying that option's
    default (§4.2); for an array, the declared `default` (the empty
    collection when none is declared), compared element-wise — `count` is a
    capacity, not a length, so nothing is padded to it (§3). Absence
    reconstructs exactly this default (init rule above),
    so the omission is value-preserving by construction — and it is the same
    test §3 already applies to a compact scalar array, so the two array forms
    now agree.
  - a sequence whose value **differs** from that default is **framed** with
    `sequence_begin`/`sequence_end`, its children again subject to the
    per-field rule. For a `struct` that frame is never empty: a value differing
    from the field's default differs in at least one child, and the per-field
    rule writes that child.
  - a `union` has the one **degenerate case**, and it is resolved by omission.
    When the active option is not `default_id` but equals **that option's own
    default**, the per-field rule writes no child, so framing would yield an
    empty frame. Such a union **MUST be omitted**, exactly like a default one.
    Nothing is lost: an empty union frame decodes to `default_id` (§4.2) —
    precisely what absence reconstructs — so the two are the same value, and the
    identity of the active option is gone either way (the pre-existing §4.2
    identity loss, unchanged here). A conformant encoder therefore **never emits
    an empty `struct`/`union` frame**; every empty frame on the wire is an
    *array* position.

  **What an empty frame denotes (normative).** A decoder **MUST** accept a
  sequence that is present but carries no child. It always means *everything
  inside it is at its default*; what that value **is** follows from the position
  the sequence occupies, and the three positions do not agree:

  - an **array wrapper** → the **empty array**, length `0`. This is the faithful
    counterpart of JSON `[]` (*Empty ≠ absent* below) and one of the **two**
    positions where a conformant encoder emits an empty frame at all — the other
    is the array element below, so both are array positions. Here it is emitted
    only where it is needed: when the field's declared `default` is non-empty, so
    that absence would reconstruct that default instead of the empty collection.
    Where the declared `default` is itself empty, absence denotes the same value
    and is the canonical form.
  - a **`struct`/`union` field** → exactly what its **absence** yields: every
    child at its declared default, a union at `default_id`. The two forms denote
    the same value, so the empty frame is a **non-canonical encoding of the
    omitted field** and a decoder treats it as omitted; a re-encode normalizes it
    away, exactly as a non-minimal varint (CORELIB_PLAN §4.1) and a trailing
    default array run (§3) are normalized. A conformant encoder never emits it —
    the one union value that would otherwise produce one is omitted instead
    (≠-default bullet above).
  - an **array element that is itself a sequence** → an **all-default element**,
    which is *still present*. Its id counts toward the array's length (*highest
    present id + 1*, §5.1). At the array's **last** index that presence is what
    fixes the length, so a decoder **MUST NOT** treat it as absent and an encoder
    **MUST** write it — which is precisely why an all-default **element** at that
    position keeps its frame while an all-default **field** never does. In the
    array's **interior** the frame is optional: the same value is denoted by an id
    gap, and a conformant encoder omits it (§2 sparse rule below).

  An encoder that framed every sequence (the pre-uniform behaviour) therefore
  stays readable in both directions: every frame it emits that this rule would
  have omitted decodes to the same value.

  **Consequence — an all-default message encodes to zero bytes.** With every
  sequence omitted, a message whose every field equals its default is the **empty
  byte string** (already true today for a schema with no sequence field). It is a
  valid message denoting the all-default value; the decode outcome for a
  zero-length input is CORELIB_PLAN §5.2, and a transport that cannot carry a
  zero-length payload must frame it explicitly.

  *Rationale:* the predicate is the **conjunction of the per-field tests the
  encoder already performs**, never a whole-object byte comparison — struct
  padding and in-memory layout never enter it, and a non-zero nested default is
  handled by the same per-field test as everywhere else. §3 and §5.1 already
  require exactly this composite predicate in order to decide whether an interior
  *sequence-form element* is written at all, so no new machinery is introduced. Framing
  an all-default subtree costs two bytes per sequence node (more for a large id —
  CORELIB_PLAN §4.3) and carries no information: with no presence bit (below),
  *absent* and *present-but-empty* are the same value.
- **Sparse omission reaches into wrapper-array elements — both element kinds.**
  A wrapper-sequence array (§5) *is* a sequence and its elements *are* its child
  fields (`id = index`, §5.1), so the per-field rule above applies to them with no
  new machinery. One rule governs both kinds, and it follows from where the length
  comes from: a wrapper carries no length field, so the decoded length is *highest
  present id + 1* (§5.1) — **nothing that carries the length may be elided, and
  everything else may be**.
  - **Interior elements are sparse.** An element before the last one that equals
    its element default **MUST be omitted**, leaving an id **gap**: a
    `string`/`blob` element is simply not written, and a `struct`/`union`/nested-array
    element is not framed either. The decoder restores every absent `dest[id]` from
    the element default, so the value is unchanged. (A decoder still accepts a
    present, default-valued interior element — a `""` leaf or an empty frame — for
    robustness; a conformant encoder never emits one, so the encoding stays
    canonical and a re-encode normalizes it away.)
  - **The last element is always present (normative).** The element at the highest
    index is the only one whose presence the length depends on, so an encoder
    **MUST** write it even when it equals its element default — a `string`/`blob`
    element as its (default) value, a sequence element as an **empty frame**. This
    holds for **every** wrapper array, with or without a schema `count`: `count` is
    a capacity, never a length (§3), so it can never restore an elided tail.

  `["a", ""]` and `["a"]` are therefore different values with different encodings,
  and an all-default `["", ""]` is written as its final element alone, at id `1` —
  not as the empty array. `[x, default, default]` is written as element `0` plus an
  empty/default element at id `2`; element `1` is the gap.

  A wrapper array is therefore, on the wire, **indistinguishable from a struct
  whose default-valued fields are omitted** — it is the same rule, not an analogy.
  **Scope:** this reaches *only* sequence-form arrays (§5). The compact scalar
  arrays of §3 are serialized linearly and gap-free — their elements carry no
  `(id, type)` header, so per-element id-gap omission never applies to them
  (a compact array carries every element it holds — §3).
- **No presence / is-set bit** (proto3-style). The application gives the zero
  value meaning where needed — e.g. a command enum with `NONE = 0` whose handler
  does nothing.
- **Empty ≠ absent — at the *array* level.** The wire can now carry an explicit
  empty array and an empty sequence (CORELIB_PLAN §4.7, §4.9), so:
  - *absent* → reconstructed as the default (which may be non-empty, e.g.
    `default: [3, 4]`);
  - *explicit empty* → the empty collection, overriding a non-empty default.
    This holds for **every** array: a declared `count` bounds how many elements
    may be carried, it does not give the array a minimum length (§3).
  - when the field's `default` **is** the empty collection, *absent* and *explicit
    empty* denote the **same value**; the two wire forms are interchangeable and
    the **canonical** one is *absent* — the sequence is omitted (≠-default bullet
    above). The distinction is observable only for a field whose declared
    `default` is non-empty.

  This is what enables a faithful JSON `[]` ↔ SofaBuffers round-trip, and it is
  the **only** place where an empty frame and an absent field differ. For a
  sequence that is not an array — a `struct` or `union` field — the two denote the
  same value, which is why that empty frame is never emitted and is decoded as if
  the field were omitted (≠-default bullet above).

  At the **element** level the sparse rule above gives the opposite — but only in
  the array's **interior**: a default-valued `string`/`blob` element there is
  **indistinguishable from an absent one** (both reconstruct to the element
  default), so omitting element 1 of `["a", "", "c"]` denotes the same value. The
  **final** element is exempt: it is always written (rule above), so an array's
  length round-trips exactly and `["a", ""]`, `["a"]` and `[]` are three distinct
  encodings of three distinct values.

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

- `count` in the schema declares an array's **capacity** — the maximum element
  count, **never on the wire**. The wire carries the element count `M`,
  `0 .. N` (CORELIB_PLAN §4.7), and that `M` **is the array's length** (normative
  rule below); `M > N` is `INVALID` (§7). `count` is **optional**, exactly like
  `maxlen`: omit it for an unbounded collection (heap targets); declare it to bound
  the array — which is also what lets heap-less targets pre-size the buffer.
- A zero-length array is valid — an **explicit empty array**. Its exact wire form
  (including why an empty fixlen array still carries its `fixlen_word`) is
  byte-level encoding and lives in CORELIB_PLAN §4.7–4.8; all that matters at this
  layer is that an explicitly empty array **is representable** (§2).
- **No interior sparsity here.** A compact scalar array is serialized
  **linearly and gap-free**: the `M` elements named by the count prefix are all
  present, in order, with no per-element header — a default-valued element
  stays on the wire, and so does a trailing one — `M` is the length, so eliding it
  would shorten the array (below). The id-gap omission of §2/§5.1 applies **only**
  to wrapper-sequence arrays (string/blob/struct/union elements), never to these
  count-prefixed forms.
  The array as a whole follows the ordinary ≠-default field test of §2.

**`count` is a capacity, not a length (normative).** A field declared `count: N`
may carry **`0 .. N` elements**; `N` is the maximum, and the schema contract
defines it as exactly that (*"Capacity (maximum element count) … the wire may
carry 0 .. count elements"* — the generator's `sofabuffers-schema-v1.json`). It
**never appears on the wire**: it exists so a heap-less target can pre-size a
buffer, and so an over-long array is invalid. Omitting `count` declares a
dynamic/unbounded array (§7.2); the two differ only in whether that bound exists.

**The wire count `M` is the array's length.** `M` **MUST** satisfy `0 ≤ M ≤ N`;
`M > N` is the `INVALID` decode outcome (§7). A decoder materializes **exactly the
`M` elements the wire carries** — the same value on a pre-sized target and on a
growable one; a target pre-sized to `N` leaves the slots at `[M, N)` at their
element default and reports a length of `M`. There is **no fill-to-`N`**: `M = 3`
in a `count: 5` array is a three-element array, and a `count` is not a promise
that five elements exist.

**Canonical encoding.** Whether the field appears at all is the ordinary ≠-default
test of §2, applied to the array's value; a schema `default` is compared as
declared, never padded to `N` (§6). When the field is emitted, the encoder writes
**every** element it holds: a trailing element equal to the element default is
**not** elided, because `M` is the length and dropping it would shorten the array —
`[1, 2, 3, 0, 0]` and `[1, 2, 3]` are different values and encode differently
(`M = 5` and `M = 3`). `M = 0` is the **empty array**, the explicit-empty form of
§2. This is the same principle the wrapper form obeys from the other side (§5.1):
nothing that carries the length may be elided.

*(This clause changed with the capacity reading. It previously declared a
`count: N` array "fixed-length with exactly `N` logical elements", had the encoder
trim the trailing default run and the decoder refill `[M, N)`. That trim is lossy
once `count` is a capacity — it silently shortens the array — so it is gone;
implementations that ship it must stop.)*

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
sequence means "no option active" → `default_id` — the same value its *absence*
yields, so a default union is canonically **omitted** (§2). A conformant encoder
never emits an empty union frame: the one value that would otherwise produce
one — an active option that is not `default_id` but equals that option's own
default — is **omitted** instead, denoting the same `default_id` value (§2). A
decoder still accepts an empty frame and decodes it identically, as the omitted
field.

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
contain gaps**: an *interior* element equal to its default is omitted (§2) —
either kind, a `string`/`blob` value or a whole sequence element — so ids such as
`0, 2, 3` are well-formed, not an error. Only the **last** index is never a gap. (Languages with 1-based
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
empty wrapper (a sequence with no children) is the explicit empty array — emitted
only when the field's declared `default` is non-empty; with an empty default the
canonical form of the empty array is the omitted field (§2).

(Array-of-composite also requires no new decoder machinery in a corelib — an
implementation note in CORELIB_PLAN §4.9. The only bound relevant at this layer is
that skipping/nesting stays within `MAX_DEPTH = 255`.)

**Sparse elements & default reconstruction (normative).** An element equal to its
element default is **not** written (§2) — a `string`/`blob` value is skipped, a
`struct`/`union`/nested-array element is not framed — **unless it is the array's
last element**, which is always present so that the length below is recoverable
(as its default value, or as an empty frame). Before applying a wrapper array a
decoder **MUST** initialise every destination slot to its element default — a
target pre-sized to the schema `count`/`maxlen` on heap-less profiles, or a fresh
buffer sized to the transmission — then write each present element at `dest[id]`,
leaving absent ids at their default.

**Array length is *highest present id + 1*, for every wrapper array.** The wrapper
carries no length field, so the highest index is what fixes it — exactly, because
that element is never elided. A schema `count: N` does **not** change this: it is a
**capacity** (§3), so it bounds the array (an element id `≥ N` is `INVALID`, §7) and
lets a heap-less target pre-size, but it never adds elements a decoder did not
receive. A target pre-sized to `N` therefore reports a length of *highest present
id + 1* and leaves the remaining slots at their element default, recovering the same
value a growable target does. An **interior** default element is indistinguishable
from an absent one (§2) — by design, and lossless against a default-initialised
destination — but it can never be the one that fixes the length. A decoder **MUST**
accept these gaps; when the element type has no default, supplying a cleanly
initialised destination is the application's responsibility.

**No trailing elision in a wrapper array, of either element kind (normative).**
Because the length is *highest present id + 1*, dropping a trailing element
shortens the array — so the last element is always written, whatever its value and
whatever its kind, and whether or not the field declares a `count` (§2). Only the
**interior** is sparse. An array with **no element at all** is the empty array; the
wrapper sequence is then **omitted** by the ≠-default rule of §2 — unless the
field's declared `default` is non-empty, where the empty wrapper is retained as the
explicit-empty form. `[s, default]` and `[s]` are different values on every target,
pre-sized or growable.

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
element default; the recovered array is `["A", "", "C"]`. Only element 1 qualifies:
element 2 is the array's **last**, so it would be written even if it also equalled
`""` — that is what fixes the recovered length at 3 (§2, last-element rule).

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
its index id (§5.1). Schema `count` is a **capacity** (§3): a heap target
omits it for an unbounded map; a heap-less target declares it to pre-size, which
bounds the map at `N` entries without asserting that `N` exist — the entry count is
*highest present id + 1*, and the unused slots of a pre-sized target stay at their
all-default value (the natural "empty slot" sentinel for a fixed-capacity map). A
length is still never baked into the *wire*: entries remain end-delimited, the
interior is sparse, and the last entry is always written (§5.1).

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

- `items.count` is **optional** (like `maxlen`): present → the array is **bounded
  at `N`** — the wire carries `0 .. N` elements, that count *is* the length (no
  fill-back, §3), and heap-less targets pre-size from it; omitted →
  dynamic/unbounded. It never appears on the wire.
- the array `default` may be **shorter than, or empty relative to,** `count`
  (`minItems` dropped; `maxItems ≤ count` kept), so an explicit `default: []` can
  override a non-empty default (§2). A shorter `default` stands for itself — it is
  not padded to `count`, which is a capacity (§3).

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
  `≥ N` (§3, §5.1), a `string`/`blob` whose wire byte length exceeds its schema
  `maxlen` (§2), or an **integer scalar whose wire value exceeds its declared
  width** (§1), is malformed input and **MUST** be reported as `INVALID`,
  the same terminal outcome as the corelib's own (CORELIB_PLAN §5.2) — never as
  `INCOMPLETE`, never silently truncated to the bound, and (for a scalar) never
  masked to its width.

### 7.1 A declared bound binds every target (normative)

A schema `count: N` on an array, a `maxlen: L` on a `string`/`blob`, and the
**declared width** of an integer scalar (`u8`…`u64`, `i8`…`i64` — §1) are
**wire-validity bounds**, not sizing hints. They bind **every implementation,
regardless of its allocation strategy**: a heap-less target that pre-sizes a buffer
from the bound and a heap target that allocates per message **MUST both reject**
input that exceeds it, with the same `INVALID` outcome.

A decoder **MUST NOT** accept an over-bound value merely because its storage happens
to be able to hold it — a `u8` field whose value arrives as `16383` is rejected even
though the corelib's ≥64-bit varint accumulator (CORELIB_PLAN §4.1) can hold it,
exactly as an over-`maxlen` string is rejected on a heap target that could store it. Whether the bound is enforced must not be an emergent property
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
conformance — including a scalar value that exceeds its declared width — is not a
wire-type question and is outside this clause; it is a schema-bound validity check,
handled as `INVALID` under §7.1.

**Against a schema bound, this clause wins.** For a **fixlen array** the element count
sits on the wire *before* the element subtype (CORELIB_PLAN §4.8), so a decoder that
enforced its schema `count` (§7.1) as it read the count word would reject a field this
clause says to skip — making the verdict depend on the count of a field that is not the
declared field's value. The subtype is therefore decided first and the schema bound
applied only to a field that survives it; CORELIB_PLAN §4.8 states the decode order, the
format ceilings that still apply meanwhile, and the resulting `INCOMPLETE`-not-`INVALID`
outcome for a message truncated between the two words.

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
