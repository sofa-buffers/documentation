# SofaBuffers — Future Ideas & Deferred Decisions

A parking lot for ideas that came up during design but were intentionally **not**
built yet, so they are not forgotten. Each entry notes what it is, why it was
deferred, and what it would touch (wire / schema / codegen). None of these are
committed designs — they are candidates to pick up when a concrete need appears.

Related specs: [`CORELIB_PLAN.md`](CORELIB_PLAN.md) (wire format),
[`MESSAGE_SPEC.md`](MESSAGE_SPEC.md) (schema → wire marshalling).

---

## A. Collection features

### A1. Sparse arrays
Because an array element's id **is** its 0-based index (MESSAGE_SPEC §5.1), the
wire can already express gaps: a missing index simply means "that element is the
default." Today we require **dense, ascending** elements.
- **Why deferred:** no demand yet; dense is simpler and matches the common case.
- **Impact:** none on the wire; a schema opt-in (e.g. `sparse: true`) plus codegen
  to leave gaps at their default. Natural extension when needed.

### A2. Map as a first-class schema type
A map is currently the pattern `array of struct{ key, value }` (MESSAGE_SPEC §5.4).
A `type: map` could be schema sugar that lowers to exactly that on the wire.
- **Why deferred:** the pattern already works; sugar is pure convenience.
- **Impact:** schema + codegen only; **no wire change** (still array-of-struct).

---

## B. Wire-format optimizations

### B1. Packed fixed-width-struct arrays
An `array of struct` where the struct is fixed-width (all scalar/fixlen fields)
could be packed like a fixlen array (`count × struct_size`, contiguous) instead of
a wrapper sequence with per-element framing — saving the `sequence start` + `0x07`
(and the per-element index header) on every element.
- **Why deferred:** needs the format/generator to track "fixed-width struct"; the
  wrapper-sequence form is correct and general in the meantime.
- **Impact:** new wire encoding (or a reuse of the fixlen-array path) + schema flag
  + codegen. Pays off for large arrays of small PODs (point clouds, mesh data).

### B2. Implicit element-count for fixed, always-full arrays
For a scalar array whose schema `count` is fixed and that is always full (e.g.
`RGB[3]`, `uuid bytes[16]`), the wire could omit `element_count` since both sides
know it from the schema — saving one byte.
- **Why deferred:** small win; conflicts with the fixed-count trailing-default
  compaction (MESSAGE_SPEC §3, which deliberately puts a `0 .. N` count on the
  wire so the trailing default run can be elided). Only safe for arrays
  declared "always full."
- **Impact:** wire (a count-less array variant or a schema "fixed/full" marker) +
  codegen.

---

## C. Schema validation

### C1. Deep default-value validation for composite-element arrays
For `array of struct/union/array`, the `default` is currently validated loosely
(a generic array bounded by `count`); the per-scalar range checks only apply to
scalar element arrays.
- **Why deferred:** validating nested struct/union default shapes in JSON Schema is
  very verbose for limited benefit (the generator validates anyway).
- **Impact:** schema only (more conditional `allOf` blocks).

---

## D. Field presence & update semantics

### D1. Optional field presence (is-set / hasbit)
Today there is **no** presence bit: a message is initialized to defaults and the
decoder sets only the fields it sees (MESSAGE_SPEC §2). This cannot distinguish
"explicitly set to the default value" from "not sent" — which only matters for
**PATCH / merge** semantics. Mirrors the proto2 hasbit / proto3 `optional` story.
- **Why deferred:** overkill for value-semantics (whole-message) transport; costs a
  presence bit + API surface in every language. Most use cases design around the
  zero value (e.g. an enum `NONE = 0`).
- **Impact:** codegen + a wire/representation choice; introduce only as an explicit
  **opt-in** if partial updates are ever needed.

### D2. FieldMask-style partial updates
The alternative to per-field presence for "update only these fields": carry an
explicit list/mask of the fields to change (cf. `google.protobuf.FieldMask`).
- **Why deferred:** same trigger as D1 (only for PATCH/merge); not needed for
  value-semantics.
- **Impact:** a convention/message type + codegen; no core wire change.

---

## E. Recursive types

### E1. Encoder cycle / depth guard
Recursive types (trees, linked lists) are expressible via `$ref` to a `$defs`
struct (MESSAGE_SPEC §5.4) and are allowed. Decode is bounded by `MAX_DEPTH = 255`.
Encode of a **cyclic** in-memory object graph (a node pointing back to an ancestor)
would loop forever.
- **Why deferred:** trees are acyclic by construction; it is an implementation
  hardening task, not a format change.
- **Impact:** generated encoder should guard with the same `MAX_DEPTH` budget and
  error rather than spin. Optionally: a way to mark/limit recursion in the schema.

---

## F. Open reconciliation tasks (not features)

### F1. Align the generator's existing string/blob array encoding with id = index
MESSAGE_SPEC §5.1 defines array element id = 0-based index. The generator already
emits `string`/`blob` arrays as sequences, so its encoder must use the same
convention.
- **Action:** verify (and if needed update) the generator/`corelib-*` encoder and
  conformance vectors so existing string/blob arrays carry `id = index`.
