# SofaBuffers Test Vectors

`test_vectors.json` is the **language-agnostic conformance suite** for the SofaBuffers wire format. Every `corelib-<lang>` implementation must copy this file from the `documentation` repository and validate against it. When this file and `ARCHITECTURE.md` disagree, this file wins.

---

## Top-level schema

```json
{
  "format":      "sofabuffers-test-vectors",
  "version":     1,
  "description": "<human-readable summary>",
  "notes":       { ... },
  "vectors":     [ ... ]
}
```

| Field | Type | Meaning |
|-------|------|---------|
| `format` | string | Fixed sentinel — reject the file if it does not match. |
| `version` | integer | Schema version. Currently `1`. |
| `description` | string | Human-readable summary of how the file was produced. |
| `notes` | object | Encoding conventions that apply throughout the file (see below). |
| `vectors` | array | Ordered list of test vectors. |

---

## Notes object

The `notes` block documents the encoding conventions used in the JSON payload. Implementations must respect these when reading the file.

| Key | Value |
|-----|-------|
| `byte_order` | `"little-endian"` — all multi-byte values in the wire format are little-endian. |
| `serialized.hex` | Lowercase hexadecimal of the complete serialized message; this is the authoritative ground truth. |
| `integers` | Decimal JSON number literals covering the full `u64`/`i64` range. |
| `floats` | Finite values encoded as JSON numbers; `+∞` and `−∞` as the string literals `"inf"` and `"-inf"`. |
| `blob.value_hex` | Lowercase hex of the blob payload bytes. |
| `array.element_type` | Describes the input element width and signedness fed to the encoder — one of `u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`, `i64`, `fp32`, `fp64`. |

---

## Vector object schema

Each entry in `vectors` has the following shape:

```json
{
  "name":        "unsigned_0x7F",
  "group":       "scalar/unsigned",
  "description": "Unsigned varint at field id 0 covering a varint length boundary.",
  "offset":      0,
  "fields":      [ ... ],
  "serialized":  { "length": 2, "hex": "007f" }
}
```

| Field | Type | Meaning |
|-------|------|---------|
| `name` | string | Unique identifier for the vector. Used in test failure messages. |
| `group` | string | Category path (see [Groups](#groups)). Useful for filtering or skipping groups on constrained builds. |
| `description` | string | Human-readable explanation of what the vector tests. |
| `offset` | integer | The encoder start offset — number of bytes left blank at the beginning of the output buffer before the first encoded byte. Implementations that support a configurable start offset must honour this. Typically `0`. |
| `fields` | array | Ordered list of encode operations (see [Field operations](#field-operations)). |
| `serialized.length` | integer | Expected byte length of the serialized output (including `offset` leading bytes, which are zero). |
| `serialized.hex` | string | Expected output as lowercase hex. This is the authoritative ground truth for both encode and decode tests. |

---

## Field operations

`fields` is an ordered list of operations that the encoder must execute, in order, to produce `serialized.hex`. Each operation is an object with an `"op"` discriminator and type-specific additional keys.

### `unsigned`

```json
{ "op": "unsigned", "id": 0, "value": 127 }
```

Writes an unsigned 64-bit integer as a varint. `value` is a non-negative decimal integer.

### `signed`

```json
{ "op": "signed", "id": 0, "value": -42 }
```

Writes a signed 64-bit integer using zig-zag + varint encoding. `value` is a decimal integer (may be negative).

### `boolean`

```json
{ "op": "boolean", "id": 0, "value": true }
```

Writes a boolean. Encoded on the wire identically to `unsigned` with value `1` (true) or `0` (false).

### `fp32`

```json
{ "op": "fp32", "id": 0, "value": 3.1415 }
```

Writes a 32-bit IEEE-754 float as a fixlen field (4 payload bytes, little-endian). `value` is a JSON number or `"inf"` / `"-inf"`.

### `fp64`

```json
{ "op": "fp64", "id": 0, "value": 3.1415926500000002 }
```

Writes a 64-bit IEEE-754 double as a fixlen field (8 payload bytes, little-endian). `value` is a JSON number or `"inf"` / `"-inf"`.

### `string`

```json
{ "op": "string", "id": 0, "value": "Hello Couch!" }
```

Writes a UTF-8 string as a fixlen field. The wire payload is the raw UTF-8 bytes **without** a null terminator.

### `blob`

```json
{ "op": "blob", "id": 0, "value_hex": "0102030405" }
```

Writes arbitrary binary data as a fixlen field. `value_hex` is the payload in lowercase hex. An empty string (`""`) encodes a zero-length blob.

### `array`

```json
{ "op": "array", "id": 0, "element_type": "u32", "values": [1, 2, 3] }
```

Writes an array of integers or floats.

| Key | Meaning |
|-----|---------|
| `element_type` | Input element type: `u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`, `i64`, `fp32`, `fp64`. |
| `values` | JSON array of element values. Integer elements are decimal numbers; float elements are JSON numbers or `"inf"` / `"-inf"`. |

Integer arrays (`u*` / `i*`) use wire type `0b011` (unsigned) or `0b100` (signed). Float arrays (`fp32` / `fp64`) use wire type `0b101` (array of fixlen) with a shared per-element `fixlen_word`.

### `sequence_begin`

```json
{ "op": "sequence_begin", "id": 1 }
```

Opens a nested sequence (wire type `0b110`). Every `sequence_begin` must have a matching `sequence_end`.

### `sequence_end`

```json
{ "op": "sequence_end" }
```

Closes the most recently opened sequence. Encoded as the single byte `0x07` (id=0, type=`0b111`). Has no `id` key.

---

## Groups

Vectors are organized into groups by their `group` field. Implementations may use groups to filter tests (e.g. skip `array/float` on a build without fp64 support).

| Group | What it tests |
|-------|---------------|
| `scalar/unsigned` | Varint boundary values for unsigned integers (every varint-byte-count boundary from 1 to 11 bytes). |
| `scalar/id` | Minimum (`0`) and maximum (`2,147,483,647`) field IDs. |
| `scalar/signed` | `INT64_MIN` and `INT64_MAX` via zig-zag + varint. |
| `scalar/boolean` | Boolean `true` (boolean `false` is covered by the unsigned `0` vector). |
| `scalar/float` | `fp32` and `fp64` finite values. |
| `scalar/string` | Non-empty and empty UTF-8 strings. |
| `scalar/blob` | Non-empty and empty blobs. |
| `array/integer` | Integer arrays for all eight element types (`u8`–`u64`, `i8`–`i64`), including boundary values. |
| `array/float` | `fp32` and `fp64` arrays including `±MAX`, `±0`, `±inf` special values. |
| `sequence` | Nested sequences (single level, with arrays, ten levels deep). |
| `composite` | A large message mixing all field types, nested sequences, and arrays — the "everything" test. |

---

## Using the vectors in tests

### Encode test

For each vector:

1. Create a fresh encoder with start `offset` bytes reserved.
2. Execute each operation in `fields` in order.
3. Flush / finalize the encoder.
4. Assert the output bytes equal `serialized.hex` (decoded to bytes).

### Decode test

For each vector:

1. Decode `serialized.hex` to a byte slice.
2. Feed the bytes into a fresh decoder.
3. Assert the recovered field sequence matches `fields` — same ops, same IDs, same values, same order.

### Chunked-streaming tests (mandatory)

The test vectors must also pass when bytes are delivered in small pieces:

- **Encode:** drive the encoder with an output buffer smaller than the message; concatenate all flushed chunks and compare to `serialized.hex`.
- **Decode:** feed the serialized bytes **one byte at a time** (and also in small odd-sized chunks); assert the decoded result is identical to a single-call decode.

### Skip tests

Feed a vector's bytes into a decoder that skips some or all fields; assert the decoder resyncs correctly and the following byte position is consistent with `serialized.length`.

### Malformed-input tests

These are not covered by the vectors themselves, but every implementation must additionally test truncated varints, overlong varints, unbalanced sequence ends, and oversized lengths — each must produce a well-defined error, never a crash or silent corruption.

---

## Float special values

Float `values` entries use these string literals for non-finite values:

| JSON value | IEEE-754 meaning |
|------------|-----------------|
| `"inf"` | Positive infinity (`+∞`) |
| `"-inf"` | Negative infinity (`−∞`) |

NaN is intentionally excluded from the test vectors; implementations are not required to round-trip NaN.

Negative zero (`-0`) is encoded as a JSON number `0` but must be preserved as a distinct bit pattern on the wire — `array_fp32_specials` and `array_fp64_specials` cover this.
