# Generator schema/example changes — REVIEW ONLY

These files belong to the **`sofa-buffers/generator`** repo, NOT to this
`documentation` repo. This folder is a scratch review drop — **do not commit it
here**. When approved, the two files replace their upstream counterparts and go
into a PR on `sofa-buffers/generator`.

| File here | Target path in `sofa-buffers/generator` |
|-----------|------------------------------------------|
| `sofabuffers-schema-v1.json` | `schema/sofabuffers-schema-v1.json` |
| `example.yaml` | `examples/messages/example.yaml` |

`schema.diff` / `example.diff` are unified diffs vs. the current upstream files.

## What changed & why

Goal: let arrays carry **composite** elements (struct / union / array), so the
schema can express the nested structures defined in `MESSAGE_SPEC.md`
(array-of-structs, array-of-arrays, array-of-unions), plus the relaxations
implied by the zero-length-array change.

### `sofabuffers-schema-v1.json`  (−33 / +75 lines, surgical)

1. **New recursive `$defs/arrayItems`.** Array element `type` now also allows
   `struct`, `union`, `array`. Per-type conditionals require the matching
   sub-definition: `struct → fields`, `union → oneof` (+ optional `default_id`),
   `array → items` (the recursion). `maxlen` stays restricted to `string`/`blob`.
2. **Array field `items` → `{ "$ref": "#/$defs/arrayItems" }`** — this is what
   enables nesting / recursion (array of arrays).
3. **`default.minItems` removed.** Capacity semantics: the wire carries
   `0 .. count` elements, so a `default` may be shorter than (or empty relative
   to) the declared capacity. The `maxItems <= count` bound stays.

`items.count` keeps `minimum: 1` — it is the array's **capacity** N, not the wire
count (which may be 0).

### `example.yaml`  (append-only, ids 22–25)

- `somestructwitharray` — an array field living inside a struct (already valid;
  now demonstrated).
- `somestructarray` — array of `struct { x:i32, y:i32 }`.
- `somematrix` — array of array of `u32`.
- `someunionarray` — array of `union { asint:i32 | asstring:string }`.

## Validation (ajv, draft-07, `$data` enabled; generator custom keywords stubbed as no-ops)

- original example vs **extended** schema → VALID (no regression)
- extended example vs extended schema → VALID
- array-of-array-of-struct (recursion) → VALID; empty `default: []` → VALID
- negative tests all correctly **INVALID**: array-of-struct without `fields`;
  scalar element carrying `fields`; array element without inner `items`;
  `maxlen` on a struct element; union element without `oneof`.

## Not covered (deliberately, open for your review)

- `enum` / `boolean` / `bitfield` as **array element** types were left out (only
  struct/union/array were added). Trivial to add later if wanted.
- Deep validation of `default` values for **composite** element arrays is loose
  (a generic array bounded by `count`); validating nested struct/union default
  shapes in JSON Schema would be very verbose.
