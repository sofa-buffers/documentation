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

- `count` in the schema is the array's **capacity** N. On the wire the
  `element_count` is the **actual** number of elements, in `0 .. N`; the decoder
  validates `≤ N`.
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

Elements are **positional** — the decoder collects children in wire order. Every
element child uses the **fixed conventional id `0`**; the decoder uses position,
not the id. (This intentionally relaxes the "unique ids per scope" expectation
that applies to structs — for an array the repeated id *is* the array.) A fixed id
keeps element headers one byte and imposes no length cap. The wrapper sequence
carries the array field's own `id` in its parent scope; an empty wrapper is the
explicit empty array.

### 5.2 The cases

| Case | Wire structure | Status |
|------|----------------|--------|
| **struct with arrays** | the struct is a sequence (§4.1); a child is a scalar array (§3) or array wrapper (below) | ✅ today — a struct field can be `type: array` |
| **array of strings/blobs** | `seq( [string id0] [string id0] … )` — elements are fixlen values | ✅ today (schema routes string/blob items to a sequence) |
| **array of structs** | `seq( elem₀:seq(fields…) elem₁:seq(fields…) … )` | ⚠ needs schema extension (§6) |
| **array of unions** | `seq( elem₀:seq(option) elem₁:seq(option) … )` | ⚠ needs schema extension |
| **array of arrays** | `seq( elem₀:‹array› elem₁:‹array› … )` — each child is a scalar array or inner wrapper | ⚠ needs schema extension |

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

---

## 6. Schema implications

The wire model supports unbounded nesting, but the YAML schema must be able to
**express and validate** it. Current `sofabuffers-schema-v1.json`:

- ✅ scalars, enum, bitfield, bool, string, blob, scalar arrays, string/blob
  arrays, nested structs, unions, and **struct-with-arrays**.
- ❌ **array of struct / union / array**: `items.type` is restricted to scalars +
  `string`/`blob`.

To allow the missing cases, `items` must become **recursive** — effectively a
field definition in its own right, so an array element can carry `fields`
(struct), `oneof` (union), or nested `items` (array), beyond the current element
types. Concretely: extend the `items.type` enum with `struct` / `union` / `array`
(optionally `enum` / `boolean` / `bitfield`); conditionally require the matching
sub-definition per element type (mirroring the `field` `allOf` blocks); recurse
validation/`default` into the nested element shape.

**The deeper the nesting we allow, the larger and more conditional the JSON schema
gets** — but it buys arbitrary composition (matrices, lists of records, lists of
variants) under one uniform wire rule (§5.3). Worth it.

Two further relaxations implied by the zero-length-array change:

- `items.count` is the **capacity** N; the wire carries `0 .. N`. So the `default`
  array need not have exactly N items — `minItems` should relax from `count` to
  `0` (today it is pinned `minItems = maxItems = count`).
- an explicit `default: []` must be allowed for array fields (the
  "override a non-empty default with empty" case, §2).
