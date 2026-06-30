# Generator schema/example changes — REVIEW ONLY

These files belong to the **`sofa-buffers/generator`** repo, NOT to this
`documentation` repo. This folder is a scratch review drop — **do not commit it**
upstream as-is. When approved, the two files replace their upstream counterparts
in a PR on `sofa-buffers/generator`.

| File here | Target path in `sofa-buffers/generator` |
|-----------|------------------------------------------|
| `sofabuffers-schema-v1.json` | `schema/sofabuffers-schema-v1.json` |
| `example.yaml` | `examples/messages/example.yaml` |

`schema.diff` / `example.diff` are unified diffs vs. the current upstream files.

## Goal

Let arrays carry **any** element type so the schema can express the nested
structures in `MESSAGE_SPEC.md` (array-of-structs/-unions/-arrays, array-of-
enum/-boolean/-bitfield, maps, recursive types), plus the relaxations implied by
the zero-length-array change.

## `sofabuffers-schema-v1.json`

1. **New recursive `$defs/arrayItems`.** Array element `type` now also allows
   `struct`, `union`, `array`, `enum`, `boolean`, `bitfield`. Per-type
   conditionals require the matching sub-definition: `struct → fields`,
   `union → oneof` (+ optional `default_id`), `array → items` (the recursion),
   `enum → enum`, `bitfield → bits`. `maxlen` stays restricted to `string`/`blob`.
   `enum`/`boolean`/`bitfield` elements lower to the existing scalar array wire
   types — no new wire form.
2. **Array field `items` → `{ "$ref": "#/$defs/arrayItems" }`** — enables the
   recursion (array of arrays, and recursive `$ref` types like trees).
3. **`count` is now optional** (was required). It is the array's **capacity**, a
   sizing hint that never appears on the wire — mirrors how `maxlen` is optional
   and "required by targets that cannot allocate dynamically". Omit it for a
   dynamic/unbounded collection (heap targets); provide it so heap-less targets
   can pre-size. This is what makes a **map** (`array of struct{key,value}`) not
   feel forced into a fixed length.
4. **`default.minItems` removed.** The wire carries `0 .. count`, so a `default`
   may be shorter than (or empty relative to) the capacity. `maxItems ≤ count`
   stays (and is simply skipped when `count` is omitted).

## `example.yaml`  (append-only, ids 22–29)

- `somestructwitharray` — array field inside a struct.
- `somestructarray` — array of `struct { x:i32, y:i32 }`.
- `somematrix` — array of array of `u32`.
- `someunionarray` — array of `union { asint | asstring }`.
- `someenumarray` / `someboolarray` / `somebitfieldarray` — scalar-on-wire arrays.
- `somemap` — `array of struct{ key:string, value:u32 }` **without `count`**
  (dynamic-length map).

## Validation (ajv, draft-07, `$data` enabled; generator custom keywords stubbed as no-ops)

Extended example vs. extended schema → VALID. Original example vs. extended
schema → VALID (no regression). Full positive/negative suite (19 cases) all pass:

- VALID: array-of-array-of-struct; array of enum/boolean/bitfield; union with an
  array option; union with a struct option; recursive tree via `$ref`; dynamic
  array without `count`; count-less array with a default; map without `count`;
  empty `default: []`.
- INVALID (correctly rejected): array-of-struct without `fields`; scalar element
  carrying `fields`; array element without inner `items`; `maxlen` on a struct
  element; union element without `oneof`; array of enum without `enum`; array of
  bitfield without `bits`; `bits` on a non-bitfield element.

Recursion note: ajv does **not** loop — the data-level `$ref` is an opaque name
(the generator resolves it), not a structure the validator expands.

## Deliberately left out (open for your review)

- Deep `default`-value validation for **composite-element** arrays (currently a
  generic array bounded by `count`); validating nested struct/union default
  shapes in JSON Schema would be very verbose.
- Recursive types are expressible via `$ref` today; runtime guardrails
  (decode `MAX_DEPTH`, encode cycle/depth guard) are described in MESSAGE_SPEC §5.4
  and belong to the corelib/generator, not the schema.
