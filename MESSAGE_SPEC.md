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
a signed int are both **signed varints** — and the schema is what disambiguates
them. Defining that lowering is the whole job of this document.

Notation in the layout sketches: `[u32 id5]` = a field of that wire type at that
id; `seq( … )` = a sequence (start … `0x07` end); identifiers are schema field
names. We never spell out header bytes — that's CORELIB_PLAN's job.

---

## 1. Leaf (scalar) types → wire

| YAML `type` | Wire type (CORELIB_PLAN) | Notes |
|-------------|--------------------------|-------|
| `u8` `u16` `u32` `u64` | unsigned integer (§4.4) | declared width is a **storage hint**; the wire is one unsigned varint regardless |
| `i8` `i16` `i32` `i64` | signed integer (§4.5) | zig-zag |
| `boolean` | unsigned integer (§4.4) | no own wire type; encoded as `0`/`1` via the corelib bool helper |
| `enum` | signed integer (§4.5) | no own wire type; carries the member's value, signed 32-bit range |
| `bitfield` | unsigned integer (§4.4) | no own wire type; flags packed by generated code at their `pos` bits |
| `fp32` | fixlen, subtype fp32 (§4.6) | |
| `fp64` | fixlen, subtype fp64 (§4.6) | |
| `string` | fixlen, subtype string (§4.6) | UTF-8, no null terminator |
| `blob` | fixlen, subtype blob (§4.6) | opaque bytes |

**Schema attributes that never reach the wire:** `decimals`, `unit`,
`description`, `deprecated` (docs/tooling hints), and `maxlen` (a
validation/sizing bound on string/blob byte length).

---

## 2. Defaults, omission, and empty-vs-absent

A **message-layer** rule; the wire spec is deliberately unaware of it (CORELIB_PLAN
§4.7 states only neutral wire mechanics).

- **Init to defaults.** A new message has every field at its schema `default` (or
  the type's zero value when none is given; a union uses `default_id`).
- **Sparse encoding.** The encoder emits a field **iff its value ≠ its default**;
  an omitted field is reconstructed as the default. (A `u8` left at default `7`
  never appears on the wire.)
- **No presence / is-set bit** (proto3-style). The application gives the zero
  value meaning where needed — e.g. a command enum with `NONE = 0` whose handler
  does nothing.
- **Empty ≠ absent.** The wire can now carry an explicit empty array
  (`element_count = 0`) and an empty sequence (`start` immediately `end`), so:
  - *absent* → reconstructed as the default (which may be non-empty, e.g.
    `default: [3, 4]`);
  - *explicit empty* → the empty collection, overriding a non-empty default.

  This is what enables a faithful JSON `[]` ↔ SofaBuffers round-trip.

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
| `enum`       | array of **signed** integers (§4.7) — enum → signed varint |
| `boolean`    | array of **unsigned** integers (§4.7) — bool → `0`/`1` |
| `bitfield`   | array of **unsigned** integers (§4.7) — packed flag word per element |

`enum`, `boolean`, and `bitfield` arrays reuse the existing scalar array wire
types — they already lower to a single signed/unsigned int — so there is **no new
wire form** for them; only the schema must permit them as element types.

- `count` in the schema is the array's **capacity** N — a sizing hint, **never on
  the wire**. The wire's `element_count` is the **actual** number of elements, in
  `0 .. N`; the decoder validates `≤ N`. `count` is **optional**, exactly like
  `maxlen`: omit it for a dynamic/unbounded collection (heap targets); provide it
  so heap-less targets can pre-size the buffer.
- `element_count = 0` is a valid **explicit empty array** (CORELIB_PLAN §4.7); for
  a float array, count 0 means no `fixlen_word` follows (§4.8).

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
somestruct: seq( [u8 nestedint id0]  [string nestedstring id1]
                 nestedstruct: seq( [i32 deepint id0] ) )
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
someunion, option2 (id1) active:  seq( [string id1] )
```

---

## 5. Nested & composite combinations

The single rule that covers every remaining case:

> **An array of composite (variable-size) elements is a *wrapper sequence* whose
> children are the elements, in order.** Each element is itself self-delimiting —
> a fixlen value (string/blob) or a nested sequence (struct / union / inner
> array) — so element boundaries are unambiguous.

Why a wrapper sequence and not "the same field id repeated" (protobuf `repeated`):
only the wrapper can represent an **explicit empty** array (an empty wrapper
sequence), staying consistent with the `element_count = 0` scalar form (§2).

### 5.1 Element identity inside an array wrapper (normative)

A wrapper sequence is an **ordinary sequence**, so — exactly like the C decoder's
state machine — **every element is a normal field with its own `(id, type)`
header**. After the wrapper's `sequence start` the decoder is back in its idle
state and reads one field header per element until the `0x07` end. There is **no
header-less element form here**; the only header-less elements are the compact
scalar arrays of §3, which are a different wire type with their own count-driven
decode states.

Each element child carries the **fixed conventional id `0`**; the generated layer
assigns elements by **position**, not by id. (This intentionally relaxes the
"unique ids per scope" rule that applies to structs — for an array the repeated id
*is* the array.) A fixed id keeps each element header one byte and imposes no
length cap. The corelib reports each element header like any other field and does
not enforce id uniqueness; mapping the id-`0` children to array slots is the
generated code's job. The wrapper sequence carries the array field's own `id` in
its parent scope; an empty wrapper (`start` immediately `0x07`) is the explicit
empty array.

**Decoder cost (minimal-footprint targets).** Array-of-composite needs **no new
decoder state**: it reuses the existing idle + sequence-push/pop + leaf states, so
a deeper element type (struct/union/array/string/blob) adds **zero `.text`** to
the decoder. Only the compact scalar arrays of §3 use the dedicated array-count
states. Skipping an unwanted array-of-composite nests through the same
`skip_depth` mechanism, bounded by `MAX_DEPTH = 255`.

### 5.2 The cases

| Case | Wire structure | Status |
|------|----------------|--------|
| **struct with arrays** | the struct is a sequence (§4.1); a child is a scalar array (§3) or array wrapper (below) | ✅ a struct field can be `type: array` |
| **array of strings/blobs** | `seq( [string id0] [string id0] … )` — elements are fixlen values | ✅ schema routes string/blob items to a sequence |
| **array of structs** | `seq( elem₀:seq(fields…) elem₁:seq(fields…) … )` | ✅ via recursive `items` (§6) |
| **array of unions** | `seq( elem₀:seq(option) elem₁:seq(option) … )` | ✅ via recursive `items` |
| **array of arrays** | `seq( elem₀:‹array› elem₁:‹array› … )` — each child is a scalar array or inner wrapper | ✅ via recursive `items` |
| **map** = `array of struct{ key, value }` | a wrapper sequence of 2-field structs | ✅ a pattern, not a distinct type |

Worked sketch — `points: array of struct{ x:i32, y:i32 }` (3 elements):

```
points: seq(
  seq( [i32 x id0] [i32 y id1] )     # element 0  (inner ids are the struct's own field ids)
  seq( [i32 x id0] [i32 y id1] )     # element 1
  seq( [i32 x id0] [i32 y id1] )     # element 2
)                                    # the three element-wrappers themselves all sit at id 0
```

### 5.3 General recursion

Any element type composes the same way: encode the element exactly as it would be
as a standalone field (leaf, scalar array, or sequence) and place it as a child
(element id `0`) of the array's wrapper sequence. Each nesting level adds one
sequence depth; the total stays within `MAX_DEPTH = 255`. There is no special case
beyond "leaf / scalar-array vs. sequence."

### 5.4 Maps and recursive types

**Map** — there is no distinct map type; a map is `array of struct{ key, value }`
(a wrapper sequence of two-field structs). Its `count` follows the rule from §3:
it is a **capacity**, **optional**, and needed only so heap-less targets can
pre-size — a heap target omits it for an unbounded map. `count` never appears on
the wire, so a "fixed length" is not baked into a map; only the actual number of
entries is transmitted.

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
**recursive** — effectively a field definition without an `id` — so every type can
be an array element:

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

- `items.count` is the **capacity** N and is now **optional** (like `maxlen`):
  present → heap-less targets can pre-size and the wire carries `0 .. N`; omitted →
  dynamic/unbounded. It never appears on the wire.
- the array `default` may be **shorter than, or empty relative to,** `count`
  (`minItems` dropped; `maxItems ≤ count` kept), so an explicit `default: []` can
  override a non-empty default (§2).

Deliberately left for later (cheap to add): deep `default`-value validation for
composite-element arrays (currently a generic array bounded by `count`).
