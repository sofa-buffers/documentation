<p align="center"><img src="assets/sofabuffers_logo.png" alt="SofaBuffers" height="140"></p>

# SofaBuffers — Corelib Implementation Plan

<b>Structured Objects For Anyone</b><br>
<i>... so optimized, feels amazing.</i>

This document specifies **what SofaBuffers is and how it works, independent of any
programming language**. It is written so that a human *or an AI* can use it as the
single source of truth to produce a brand-new **core library implementation
(`corelib-<lang>`)** in a target language, byte-for-byte compatible with every
existing implementation.

It covers:

1. The idea behind the protocol.
2. The reference repositories and the shared test-vector source of truth.
3. The core concepts — fields, IDs, scopes, and sequences.
4. The complete binary wire format (byte level).
5. The streaming model — the reason SofaBuffers exists — and the recommended
   language-idiomatic patterns.
6. A language-independent API contract — including the **generated-object layer**.
7. Mandatory unit testing using the shared test vectors.
8. The `assets/` requirement.
9. The README format every `corelib-*` repository must follow.
10. The performance-testing requirement (`perf` + `bench` tools).
11. A devcontainer for local development.
12. GitHub Actions workflows (CI + docs).
13. A conformance checklist.

---

## 1. The Idea

SofaBuffers is a **compact, self-describing, TLV-like (Type–Length–Value) binary
format** for serializing structured messages made of multiple fields, arrays, and
nested structures — comparable in purpose to Protocol Buffers, but designed around a
single hard constraint:

> **Everything must be streamable.**
> Both **serialization** and **deserialization** must work **in arbitrarily small
> chunks**, without ever needing the whole message in memory at once.

This single constraint drives the entire design:

* **No length prefix on the whole message.** A message is a flat byte stream of
  fields. Sequences (nested structures / dynamic arrays) are delimited by explicit
  *start* and *end* markers rather than by a byte count, so an encoder can emit a
  nested structure **without knowing its final size in advance**.
* **Field-at-a-time encoding/decoding.** Each field carries its own type and (where
  needed) length, so a decoder can process, skip, or route a field the instant its
  header arrives — even if the field's payload has not been received yet.
* **Minimal overhead, zero unnecessary copies.** The implementation should avoid
  copying data unless unavoidable. Buffer hand-off, field-value binding, and
  flush-callback delivery should all operate on the original bytes without
  intermediate copies.
* **Heap-free where the target demands it.** If the language can target embedded or
  bare-metal systems (AVR, Cortex-M, RL78, etc.), the implementation must be able to
  run with caller-owned, fixed-size buffers and no dynamic allocation. In managed
  languages, heap allocation during setup is acceptable; the hot path (per-field
  encode/decode) should avoid allocating.
* **Small-value bias.** Integers use variable-length encoding (varint) so that the
  common small values cost one byte. The 3-bit type tag is packed *into* the field
  ID/length varint, so a typical small field header is a single byte.

The design percentages baked into the format (which types get the cheapest
encoding) were chosen to match the average field-type usage seen across other
message formats (JSON, Protocol Buffers, and others), keeping overhead lowest for
the most frequently used types.

---

## 2. Reference Repositories (Source Inputs)

When this document and the shared test vectors disagree, the test vectors win.

| Repository | Language | Role | URL |
|------------|----------|------|-----|
| `documentation`     | -           | Format spec (this file + README), branding assets | https://github.com/sofa-buffers/documentation |
| `corelib-c-cpp`     | C99 / C++20 | C/C++ embedded | https://github.com/sofa-buffers/corelib-c-cpp |
| `corelib-cpp`       | C++20       | C/C++ high speed | https://github.com/sofa-buffers/corelib-cpp |
| `corelib-rs-no-std` | Rust no_std | Rust embedded | https://github.com/sofa-buffers/corelib-rs-no-std |
| `corelib-rs`        | Rust        | Rust high speed | https://github.com/sofa-buffers/corelib-rs |
| `corelib-py`        | Python      | Python high speed | https://github.com/sofa-buffers/corelib-py |
| `corelib-ts`        | TypeScript  | TypeScript high speed | https://github.com/sofa-buffers/corelib-ts |
| `corelib-go`        | Go          | Go high speed | https://github.com/sofa-buffers/corelib-go |
| `corelib-java`      | Java        | Java high speed | https://github.com/sofa-buffers/corelib-java |
| `corelib-cs`        | C#          | C# high speed | https://github.com/sofa-buffers/corelib-cs |
| `generator`         | -           | Schema → code generator | https://github.com/sofa-buffers/generator |

Key reference artifacts:

* `documentation/assets/` — branding, copied verbatim into every new repo:
  * `sofabuffers_logo.png`, `sofabuffers_icon.png`.
* **Shared test vectors** — the language-agnostic conformance suite. These are
  **generated by the C implementation (`corelib-c-cpp`), which is their source of
  truth** — do not hand-write a divergent copy:
  * `test_vectors.json` —
    <https://raw.githubusercontent.com/sofa-buffers/corelib-c-cpp/refs/heads/main/assets/test_vectors.json>
  * `test_vectors_README.md` (vector schema documentation) —
    <https://raw.githubusercontent.com/sofa-buffers/corelib-c-cpp/refs/heads/main/assets/test_vectors_README.md>

---

## 3. Core Concepts

A **message** is an ordered stream of **fields**. There is no envelope and no
overall length header.

* **Field** — a single `(ID, type, payload)` unit.
* **ID** — an integer chosen by the schema author identifying the field within its
  current scope. Range `0 .. 2,147,483,647`. IDs must be unique within a single
  sequence/scope but may repeat in different scopes.
* **Type** — one of 8 wire types (3-bit tag), see §4.3.
* **Sequence** — purely a wire construct: it opens a fresh ID scope and nothing
  more. Opened by a *sequence start* field and closed by a *sequence end* marker.
  It carries no type semantics of its own — that fresh scope is the only thing a
  sequence does. The message layer builds nested structures, dynamically sized
  arrays, arrays of variable-length elements (strings/blobs), and tagged unions
  on top of this single primitive; how each schema type lowers onto sequences is
  defined in [`MESSAGE_SPEC.md`](./MESSAGE_SPEC.md) §4–§5, not here.
* **Scope** — each sequence opens a fresh ID namespace; child IDs never collide with
  parent IDs.

A decoder that is not interested in a field (or an entire sub-sequence) must be able
to **skip** it using only the information in the field header.

---

## 4. Binary Wire Format

**Everything on the wire is little-endian.** Integers are encoded as varints
(LEB128-style, least-significant group first), which is inherently little-endian.
Multi-byte fixed-width values (IEEE-754 floats) are stored in little-endian byte
order. There are no big-endian fields anywhere in the format.

### 4.1 Varint Encoding

Every integer in the format — field IDs, lengths, counts, and integer values,
regardless of the declared bit width — is encoded as an **unsigned LEB128-style
varint**:

* The value is split into 7-bit groups, least-significant group first.
* Each output byte holds 7 bits of payload in its low bits.
* The **most-significant bit (0x80) is a continuation flag**: set means "more bytes
  follow", clear means "this is the last byte".

```
value 0        -> 0x00
value 1        -> 0x01
value 127      -> 0x7F
value 128      -> 0x80 0x01
value 300      -> 0xAC 0x02
value 16384    -> 0x80 0x80 0x01
```

A decoder must accumulate into at least a 64-bit register and shift by 7 per byte.

**No value before the final byte (normative).** A varint has **no value** until the
byte with a clear continuation flag arrives. A decoder **MUST NOT** evaluate any part
of an incomplete varint — neither a packed sub-field nor a partial magnitude — and
**MUST NOT** let such a part influence a decode outcome, **even when those bits are
already arithmetically fixed** and no continuation byte could change them. Until the
varint ends, the construct it belongs to is `INCOMPLETE` (§5.2).

The bits this rule is about are real, which is why it has to be stated. Each further
byte contributes a multiple of 128, and 128 is divisible by 8, so the **low 3 bits of
any varint are settled by its first byte**. Both words in this format pack a 3-bit
field there — the wire type in a field header (§4.3) and the subtype in a
`fixlen_word` (§4.6) — so a decoder *could* read either one early. It **MUST NOT**:

* a field header yields `(id, type)` only when the header varint ends;
* a `fixlen_word` yields `(length, subtype)` only when that varint ends. A message
  ending inside it is `INCOMPLETE` even when the settled low bits already carry a
  **reserved subtype** `0x4`–`0x7` (§4.6), and even when the field's id would violate
  a schema bound (MESSAGE_SPEC §7.1) once the subtype confirmed the field is the
  declared one (MESSAGE_SPEC §7.3). Those tests are satisfiable only on the complete
  word.

*(Rationale: the outcome must not depend on how far a decoder's varint loop happens to
unroll. Peeking splits one word into two decision points, so within a single
implementation a push surface reporting the completed word and a pull surface reading
its first byte reach different verdicts for the same bytes — which is exactly the
chunk-boundary sensitivity §7.2 item 4 requires every port to test against. The
`INVALID`-over-`INCOMPLETE` precedence of §5.2 is unaffected: it ranks constructs the
decoder has actually read, and an unfinished varint is not one of them.)*

**Minimality on encode, tolerance on decode (normative).** An encoder **MUST**
emit every varint in its **minimal form** — the fewest bytes that represent the
value, i.e. no continuation byte that contributes only zero high bits (the final
byte is `0x00` only in the single-byte encoding of value `0`). This is the
byte-level face of the single-canonical-encoding rule (MESSAGE_SPEC §2): `5` is
`0x05`, never `0x85 0x00`.

A decoder **MUST accept** a non-minimal varint that stays within the 64-bit
bound below, decode it to the value it denotes, and — because every re-encode is
canonical — emit the minimal form on any re-encode. A non-minimal encoding is
therefore **not** the `INVALID` outcome (§5.2); it is normalized away, exactly
as a present-but-default *interior* array element is (MESSAGE_SPEC §2). The rule
applies wherever a varint appears: field headers, `fixlen_word`s, array element
counts, element values, and inside skipped fields.

**The 64-bit bound (normative).** A varint encoding **exceeds the 64-bit value
range** — the `INVALID` decode outcome (§5.2) — iff it is longer than **10
bytes**, or any of its payload bits would land at bit position ≥ 64 (a tenth
byte with payload above `0x01`). Both tests are on the *encoding*, not the
decoded value: an 11-byte encoding is `INVALID` even when its surplus bytes are
zero, and a decoder **MUST NOT** silently discard overflowing high bits.

### 4.2 Zig-Zag Encoding (signed integers only)

Signed integers are first mapped to unsigned via zig-zag, then varint-encoded, so
that small-magnitude negatives stay small:

```
encode(n) = (n << 1) ^ (n >> (bitwidth-1))      // arithmetic shift
decode(u) = (u >> 1) ^ -(u & 1)

 0 -> 0      -1 -> 1      1 -> 2      -2 -> 3      2 -> 4 ...
```

Use 64-bit width for the zig-zag transform (values are `int64`-domain).

### 4.3 Field Header: ID + Type

Each field begins with a single varint that packs the **ID** and a **3-bit type tag**:

```
header_varint = (id << 3) | type
```

The low 3 bits are the type; the remaining high bits are the ID.

| Bits (type) | Value | Wire type                     |
|-------------|-------|-------------------------------|
| `0b000`     | 0x0   | unsigned integer (varint)     |
| `0b001`     | 0x1   | signed integer (zig-zag varint) |
| `0b010`     | 0x2   | fixlen value                  |
| `0b011`     | 0x3   | array of unsigned integers    |
| `0b100`     | 0x4   | array of signed integers      |
| `0b101`     | 0x5   | array of fixlen values        |
| `0b110`     | 0x6   | sequence start                |
| `0b111`     | 0x7   | sequence end                  |

These tag values are normative.

### 4.4 Unsigned Integer (type `0b000`)

```
[ header_varint ] [ value_varint ]
```

The value is an unsigned varint. Example: field id `0`, value `0` → `00 00`
(header `0x00`, value `0x00`). Field id `0`, value `127` → `00 7f`.

**Booleans have no wire type of their own.** A boolean is simply an unsigned integer
with the value `0` (false) or `1` (true). The **corelib must provide dedicated boolean
read/write functions** that perform this mapping — writing a boolean emits the unsigned
value `0`/`1`, and reading one interprets an unsigned field as a boolean. On the wire the
result is indistinguishable from an unsigned integer. (The shared test vectors carry a
`boolean` op accordingly; it encodes exactly as an unsigned `0`/`1`, e.g. `boolean true`
at id `0` → `00 01`.)

Other schema-level types that lower to an unsigned integer (e.g. bitfields / flag
sets) are a message-layer concern — see [`MESSAGE_SPEC.md`](./MESSAGE_SPEC.md) §1.
The corelib only ever sees a plain unsigned integer.

### 4.5 Signed Integer (type `0b001`)

```
[ header_varint ] [ zigzag(value)_varint ]
```

Decode the varint, then zig-zag-decode into a signed value.

Schema-level types that lower to a signed integer (e.g. enums, including their
32-bit value range) are a message-layer concern — see
[`MESSAGE_SPEC.md`](./MESSAGE_SPEC.md) §1. The corelib only ever sees a plain
signed integer.

### 4.6 Fixlen Value (type `0b010`)

A fixlen field carries a self-describing length-and-subtype word followed by raw
payload bytes:

```
[ header_varint ] [ fixlen_word_varint ] [ payload bytes... ]
```

`fixlen_word` packs the byte length and a 3-bit **fixlen subtype**:

```
fixlen_word = (length << 3) | fixlen_type
```

Length range `0 .. 2,147,483,647`. Fixlen subtypes:

| Bits  | Value | Subtype                                   |
|-------|-------|-------------------------------------------|
| `0b000` | 0x0 | IEEE-754 32-bit float (little-endian)     |
| `0b001` | 0x1 | IEEE-754 64-bit double (little-endian)    |
| `0b010` | 0x2 | UTF-8 string (no null terminator on wire) |
| `0b011` | 0x3 | BLOB (arbitrary binary data)              |
| `0b100`..`0b111` | 0x4–0x7 | reserved                      |

* For `fp32`/`fp64`, the payload length is **exactly** 4 / 8 bytes, and the value
  must be byte-swapped to little-endian on big-endian hosts. A `fixlen_word`
  declaring any other length for these subtypes is malformed — the `INVALID`
  decode outcome (§5.2) — and a decoder **must** reject it when the `fixlen_word`
  is read, before consuming (or waiting for) any payload bytes (§5.2, precedence
  of `INVALID` over `INCOMPLETE`).
* Float payloads are stored as **raw IEEE-754 little-endian bytes**, so every value —
  including `±0`, `±inf`, and `NaN` — round-trips **bit-for-bit**. The corelib never
  inspects or normalizes the value; `NaN` is just another float payload. (The JSON
  test-vector format cannot represent `NaN`, so the shared vectors omit it; conformance
  tests must compare floats by **bit pattern**, not `==`, since `NaN != NaN`.) In
  particular an `fp32` **signaling** NaN **must not** be quieted: a language whose
  native float value is a 64-bit double (JS/TS, Python, Dart, …) destroys the sNaN the
  instant the payload passes through that double, breaking this rule — see the
  normative implementation requirement in §6.5.
* For `string`, the payload is the raw UTF-8 bytes **without** a trailing null byte.
  Callers that need a null-terminated string must append it themselves.
* For `blob`, the payload is opaque.
* A decoder uninterested in the field skips exactly `length` payload bytes.
* Subtypes `0x4`–`0x7` are **reserved**: a decoder **must** reject a fixlen field
  carrying a reserved subtype as malformed (the `INVALID` decode outcome, §5.2).

### 4.7 Array of Unsigned / Signed Integers (types `0b011` / `0b100`)

```
[ header_varint ] [ element_count_varint ] [ elem_0_varint ] [ elem_1_varint ] ...
```

* `element_count` range `0 .. 2,147,483,647`. The count lets a decoder validate that the
  values fit the destination buffer, or skip the whole array element-by-element.
* **`element_count` may be `0`.** A zero-count array is a valid, fully-specified empty
  array on the wire — exactly `[ header_varint ] [ element_count_varint = 0 ]`, with no
  elements following. The wire format makes no claim about how an explicit empty array
  relates to an absent field; whether the two are distinguished, and what each means, is
  a code-generator concern, not a wire-level one (MESSAGE_SPEC §2).
* Each element is an independent varint (unsigned) or zig-zag varint (signed); the
  byte length per element varies.
* The declared element width on the API (8/16/32/64-bit) affects only how the
  decoded value is stored in the destination, not the wire bytes.

### 4.8 Array of Fixlen Values (type `0b101`)

```
[ header_varint ] [ element_count_varint ] [ fixlen_word_varint ] [ payload... ]
```

* A **single** `fixlen_word` describes the subtype and the **per-element byte
  length**, which applies to **all** elements.
* Payload is `element_count × element_length` contiguous bytes.
* When `element_count == 0` the array is empty: the `fixlen_word` is **still
  present** (there is no payload) — the field is exactly `[ header_varint ]
  [ element_count_varint = 0 ] [ fixlen_word ]`. The `fixlen_word` is kept even
  though there are no elements so that an empty `fp32` array and an empty `fp64`
  array stay **distinguishable on the wire**; without it both would be
  `[ header ][ count = 0 ]` and a decoder that infers the element subtype from the
  wire could not tell them apart. (Integer arrays, §4.7, have no `fixlen_word` at
  all — their element width is an API concern — so an empty integer array is just
  `[ header ][ count = 0 ]`.)
* Only fixed-width subtypes are allowed here (`fp32`, `fp64`). **Dynamic subtypes
  (string, blob) are NOT allowed in a fixlen array** — to model an array of strings
  or variable blobs, use a sequence (see §4.9).
* `fp32`/`fp64` elements are little-endian.

**Decode order: both words first, then the subtype, then the schema bound (normative).**
The `element_count` precedes the `fixlen_word`, so a decoder learns *how many* elements
there are before it learns *of what type* — and the two answers belong to different
authorities (the format bounds the count, the schema bounds the array). A decoder
therefore:

1. reads `element_count`, enforcing the **format** ceiling `ARRAY_MAX` (§6.2) as it does
   so, and allocating nothing on the strength of that count;
2. reads the `fixlen_word`, obtaining the subtype and the per-element length;
3. if the subtype **contradicts** the declared element type, **skips** the field per
   MESSAGE_SPEC §7.3 — `element_count × element_length` payload bytes — leaving the
   declared field at its default. The schema `count` **MUST NOT** be applied: the field
   was never this array's value, so its element count is not this array's count;
4. otherwise applies the **schema** `count` bound (MESSAGE_SPEC §7.1): an
   `element_count` above the declared `count` is `INVALID`.

This order is not a preference. A fixlen array cannot be skipped at all without the
`fixlen_word`, because the payload length is `element_count × element_length` — so a
conformant decoder has already read both words before it can act on the field either
way, and deciding on the subtype first costs it nothing.

Two consequences follow and are **intended**:

* A message that ends **between** the two words is `INCOMPLETE`, not `INVALID`, even
  when the `element_count` already exceeds the schema `count`. The decoder genuinely
  cannot yet know whether the field is one it must bound (§5.2's precedence gives
  `INVALID` only to bytes that are malformed *regardless of what follows*; these are
  not).
* The format ceiling still fires on the count word whatever the subtype turns out to
  be, so an absurd `element_count` is rejected before any allocation.

### 4.9 Sequence Start (type `0b110`) and Sequence End (type `0b111`)

```
sequence start:  [ header_varint = (id << 3) | 0b110 ]
   ... child fields, possibly nested sequences ...
sequence end:    [ 0x07 ]      // (id = 0) << 3 | 0b111  ==  0x07, a single byte
```

* A sequence exists **only on the wire**: its sole effect is to open a **fresh ID
  scope**. It has no type meaning of its own — nothing more than a new scope.
* **Sequence end carries no information in its id.** An encoder **MUST** emit a
  sequence end as exactly `0x07` — `id = 0` in the minimal varint form §4.1 already
  requires of every header. A decoder **MUST discard** the id: the marker closes the
  innermost open sequence whatever the id says, and re-encodes as `0x07`. The id
  sub-field exists only to keep the header format uniform (every header is one
  `(id << 3) | type` varint); on a sequence end it carries no information and never
  will, so there is nothing a sender can express by varying it.
* **Discarded is not unvalidated.** The header is an ordinary field header, and its id
  is bounded by `ID_MAX` exactly as every other header's is (§6.2): an id above the
  ceiling is `INVALID` (§5.2), on a sequence end as anywhere else. That bound is on the
  id's **value**, not on its spelling — §4.1 is untouched, so a non-minimal encoding of
  an in-range id (`0x87 0x00` for id 0, or an id of 3) is accepted, decoded and
  re-emitted as `0x07` like any other non-minimal varint. There is deliberately **no
  exception** for wire type 7: one rule covers every header, so a decoder validates the
  id at the point it reads it and never has to branch on the wire type first.
* Because the end is a marker (not a length), an encoder can stream a sequence of
  unknown size. A decoder that wants to skip a sequence must walk it to its matching
  end, descending into nested sequences and tracking depth.
* An **empty sequence** — a `sequence start` immediately followed by its `0x07` end —
  is legal and well-formed; a decoder must accept it. It is the composite-type
  counterpart of a zero-count array (§4.7); what an empty sequence *means*
  (explicit empty collection, all-default struct, …) is a message-layer concern
  (MESSAGE_SPEC §2, §4). The wire form is unconditional here — it is the message
  layer that decides *when* one is produced, and it produces far fewer of them than
  it used to: an all-default `struct`/`union` field is omitted outright, and the
  empty frame survives only where it carries information (an explicitly empty array,
  and an all-default element of a wrapper array). §6 states the encoder API that
  makes that decision expressible without buffering the message.
* That single primitive (a fresh scope) is enough to model nested structures,
  dynamically sized arrays, arrays of variable-length elements (strings/blobs),
  and tagged unions. These are all schema-level uses the corelib needn't
  distinguish — each is just a sequence on the wire; the lowering of each schema
  type onto sequences is defined in [`MESSAGE_SPEC.md`](./MESSAGE_SPEC.md) §4–§5.
* **Implementation note:** decoding a sequence-wrapped (composite) array needs no
  dedicated decoder states — after a `sequence start` the decoder is back in its
  idle state and reads ordinary field headers, so array-of-composite reuses the
  existing idle + sequence-push/pop + leaf states, and skipping one nests through
  the same depth-tracking mechanism. Only the count-prefixed array wire types
  (§4.7–4.8) need their own count-driven states.
* **Maximum nesting depth is 255** (`MAX_DEPTH`, §6.2). An encoder must not open more
  than 255 nested sequences; a decoder must reject a message that nests deeper with an
  `InvalidMessage` error rather than risk unbounded recursion / stack growth.

### 4.10 Worked Example

Message: `{ id=0: unsigned 127 }`:

```
00        header: id=0, type=0b000 (unsigned)
7f        value varint = 127
```
→ `00 7f` (2 bytes). This is exactly test vector `unsigned_0x7F`.

---

## 5. The Streaming Model (the heart of the design)

Every implementation **must** be streaming-capable on both sides. "Streaming" means
the message may be larger than any buffer the program holds, and may be produced or
consumed incrementally.

### 5.1 Streaming Serialization (Encoder)

The encoder writes into an **output buffer** and invokes a **flush/drain** operation when
that buffer fills (or on explicit flush). The flush forwards the accumulated bytes
downstream (transmit, write to file, etc.) and the encoder continues into the now-empty
buffer. The output buffer **may be arbitrarily smaller than the message** (normative):
what bounds memory is the buffer, not the message.

**Where a flush boundary may fall (normative).** The byte sequence an encoder produces is a
concatenation of **atomic units** and **divisible runs**.

Atomic: a field header varint (§4.3), a `fixlen_word` (§4.6), an `element_count` varint
(§4.7–4.8), the varint of an integer scalar or of one integer array element (§4.4–4.5,
§4.7), and one `fp32`/`fp64` element (§4.6, §4.8).

Divisible: the **payload byte run** of a `string` or `blob` (§4.6), at any byte boundary.

A flush boundary **MAY** fall between two atomic units and anywhere inside a divisible run.
An encoder **MUST** be able to split a divisible run across a flush — a field without a
schema `maxlen` can exceed any buffer, so no minimum removes that path. It **MAY** require
that each atomic unit lands contiguously.

The rule is stated over the **produced bytes**, not over the caller's data: a target whose
native string is UTF-16 emits a payload run that its input never was, and it is the run in
the buffer that a flush divides.

**`MIN_OUTPUT_BUFFER` (normative).** A corelib **MUST** expose a documented constant — the
smallest buffer it accepts **for streaming**:

* A port that splits atomic units too declares **`1`**.
* A port that requires atomic units to land contiguously declares the largest run it
  reserves as one piece. The derived floor is **10 bytes**, a 64-bit varint at
  `ceil(64/7)`; a port that reserves a header together with its value declares that sum.
* A declaration **MUST NOT** exceed **20** — a header varint and its value, `2 × 10`. That
  is the largest reservation any port makes, and it is also the smallest message a schema
  can bound: a single scalar field is at most a header plus a value. A ceiling above it
  would let a port demand more than a whole message can occupy. Reserving further ahead —
  a field's metadata as a group, or a batch of array elements — **MUST** be handled by
  flushing, not by raising the declaration.

**The minimum binds a buffer installed with a flush sink**, at installation and at every
mid-stream buffer-set. Such a buffer **MUST** satisfy `buflen - offset >=
MIN_OUTPUT_BUFFER` and is rejected **where it is handed over**, by the same mechanism the
port uses for an out-of-range offset (an exception, or an error status), never partway
through a message. Any buffer at or above it **MUST** work and **MUST** produce output
byte-identical to the one-shot path.

**A buffer installed without a sink is subject to no minimum.** No flush can occur, so no
atomic unit can be split and the constant has nothing to say: the buffer either holds the
message or reports buffer-full. This is the case a caller sizes from the generated
`MAX_SIZE` (§6.1.1), and it stays exact — a message that encodes to two bytes may be
encoded into a two-byte buffer on any port, whatever that port declares.

This is what §5.1 previously secured by fixing the floor at one byte for every port: a
caller writing portable code must be able to **discover** the size that works, rather than
find out at runtime once it is too late. A declared constant serves that directly — the
caller sizes its buffer from a value the API gives it — and confining it to the streaming
case keeps it from imposing a floor on the one-shot path, where no flush can occur and no
floor is needed.

**Declaring `1` stays fully conformant, and is the right choice for a footprint profile.**
Byte-granular encoding is what the wire format was designed around, and on a target that
streams through a scratch buffer measured in tens of bytes the byte-at-a-time path costs
less than the RAM a larger buffer would. A port that declares `1` imposes no requirement on
its caller at all. Note the direction: here the **constrained** profile is the strict one
and the max-speed profile takes the allowance — the reverse of `FIXLEN_MAX`/`ARRAY_MAX`
(§6.2) and `SOFAB_STRICT_UTF8` (§6.4). Unlike those, this allowance changes nothing on the
wire — the bytes are identical either way, and only an API precondition differs.

Required capabilities:

* Accept a **caller-supplied output buffer** — pointer/slice, length, and start offset —
  **without** a flush sink: the offset leaves room at the front for a framing header, and a
  buffer that fills reports buffer-full rather than overflowing.
* Accept the same caller-supplied buffer **together with** a flush callback, or connected to
  a language-idiomatic stream/writer sink — whichever pattern the language prefers.
* Allow a new output buffer to be installed mid-stream, under the handover contract below.
* Expose an explicit flush to drain any remaining buffered bytes at the end.
* Return a status/error code on every write operation.

A corelib **MUST NOT**:

* **allocate an output buffer.** Every buffer the encoder writes into is caller-supplied.
  There is one buffer-ownership model rather than two, and a heap-less profile is not a
  special case of it but the plain reading.
* **grow or reallocate** a buffer the caller supplied; what was handed over is what gets
  written;
* return **partial output as if it were complete** — an encoder that could not write what
  it was asked to write reports it, and a one-shot helper that ignores that report is
  non-conformant.

**The generated-object layer allocates; the corelib does not (normative).** §6.1.1 requires
a one-shot `encode()` that hands back the message as bytes, and that storage has to come
from somewhere. It comes from the generated code, which — unlike the corelib — knows the
schema: it allocates, then drives the corelib over a buffer it supplies like any other
caller. Two shapes are conformant, and the generator already emits both:

* **Bounded schema** — allocate `MAX_SIZE`, install it **without** a sink, encode in one
  pass. The worst case is derived from the schema and cannot be exceeded, so no flush can
  occur and no minimum applies.
* **Unbounded schema** — `MAX_SIZE` is then a configured ceiling, not a size the message
  cannot reach, and sizing from it would truncate a larger message. Install a scratch
  buffer **with** a flush sink that appends into the growing result instead; the ceiling
  never binds an encode, and the scratch is subject to `MIN_OUTPUT_BUFFER` like any other
  sink-installed buffer.

On a heap-less profile only the bounded shape exists, which is why MESSAGE_SPEC §7.2 already
requires a schema intended for one to declare its bounds.

**What a returning flush callback leaves behind (normative).** A sink may either **copy**
the bytes it was handed or **take** the buffer — pass it to a transport, queue it for an
asynchronous write, hand it to DMA — and the encoder cannot tell the two apart. The
contract therefore rests on what the callback does before it returns:

* Returning **without** installing a buffer means the sink **copied**. The active buffer
  stays active and the encoder resumes writing into it at offset **0**.
* A sink that **takes** the buffer **MUST** install a replacement before returning, using
  the mid-stream buffer-set operation above. It **MUST NOT** return without one: the
  encoder would keep writing into storage the transport now owns.

**The start offset belongs to the installation, not to the buffer.** Each buffer-set call
begins a new installation and its cursor starts at *that call's* offset; the offset is then
consumed, so any later flush that the callback returns from without installing anything
resumes at 0. Passing the **same** buffer to buffer-set is a new installation like any
other — that is how a sink gets fresh header room in **every** flushed unit, one framing
header per packet: `buffer_set(buf, len, offset)` re-arms the reservation, where a bare
return would not.

Both the copy-and-continue and the take-and-replace shapes are therefore expressible, and
which one is in effect is stated by the callback rather than inferred by the encoder.

*(Rationale: the zero-copy path is the reason the buffer-set operation exists — encode
straight into the packet, hand the packet on, encode the next into another. That path is
only safe if "returned without installing a buffer" has exactly one meaning. Reading it as
"the sink is done, reuse the storage" is the safe default for a copying sink and is what a
taking sink must override; reading it the other way round would make the dangerous case
the implicit one.)*

**Pass-through of a divisible run (normative, optional).** A `string` or `blob` payload can
be the one thing an encoder writes that it does not *produce*: where the wire bytes already
exist as the caller supplied them, copying them through the output buffer only to hand them
onward is a wasted pass over the payload. An encoder **MAY** therefore hand such a run to
the sink **directly**, under all of the following:

* **The caller has granted it** when installing the sink. Pass-through is **off by
  default**: a sink that was not told it may receive foreign memory never does.
* **Buffered bytes are drained first**, so what the sink receives stays in wire order.
* **The run is divisible.** Everything atomic (§ above) is produced by the encoder and
  exists nowhere else to hand over.
* **The run's wire bytes already exist**, contiguously, as memory the caller supplied.
  Divisibility says where a flush *may* fall; this says whether there is anything to hand
  over at all, and the two are not the same test.

A `blob` always satisfies the last condition — it is bytes on both sides. A `string`
satisfies it only where the port's string type already holds the UTF-8 payload (Go, Rust) or
its API takes the bytes directly (C, C++, Zig); ASCII content needs no special case, being
UTF-8 already. Where the payload has to be **transcoded** into existence — from UTF-16, as
in C#, Dart, TypeScript and Java — the wire bytes do not exist until the encoder produces
them, so there is nothing to pass through and the run is copied like any other. That is a
property of how the port stores strings, not of the string's content: an all-ASCII UTF-16
string still has to change width.

**Passed-through memory is borrowed for the duration of the call.** The sink **MUST NOT**
retain it, and such a call is **not** a buffer handover: the take-and-replace contract
above does not apply to it, installing a replacement in response to one is meaningless, and
the encoder's active buffer is unchanged by it. This mirrors the input side, where a fed
chunk is likewise borrowed only for the duration of `feed` (§6).

**Pass-through and taking the buffer are mutually exclusive (normative).** A sink granted
pass-through **MUST NOT** call the buffer-set operation, and a port **SHOULD** reject such
a call as it rejects an undersized buffer. Granting the permission *is* the promise never
to take a buffer.

The exclusion is needed because **the sink cannot tell the two calls apart.** A
passed-through run is preceded by a flush of the buffered bytes, so the sink is invoked
twice in a row with what looks like the same kind of argument — first the output buffer,
then foreign memory — and a sink whose policy is "take what I am handed, install a
replacement" would apply it to both, retaining memory it only borrowed. No rule stated over
the *sink's* intent can prevent that, so the two behaviours are separated where they are
declared instead, at installation.

This costs nothing, because it separates two populations that never wanted the same thing:
a sink that takes buffers is a zero-copy transport, which cannot use a passed-through run
anyway, and a sink that wants pass-through forwards or accumulates and never takes.

It is also what makes a **start offset** a non-issue here. A sink that wants header room in
every unit it is handed — one framing header per packet — has to re-establish the
reservation on each flush by installing a buffer (§ above: the offset belongs to the
installation and is consumed once), and installing is exactly what this rule forbids it. A
non-zero offset on its own reserves room in the *first* unit and says nothing about later
ones, so it neither implies the per-packet pattern nor conflicts with pass-through.

A port **MAY** ignore the permission entirely and always copy. That is conformant — the
output is byte-identical either way, and the permission is an invitation, not an
obligation. Ports for constrained targets are expected to ignore it.

*(Rationale: the two shapes do not compete. A transport that fragments cannot use a
passed-through run anyway — the run does not fit one packet, so the sink would have to
split it itself, at a point where no header room was reserved. Such a sink simply does not
grant the permission and nothing changes for it. A sink that accumulates or writes to a
socket has neither constraint and saves a copy of the whole payload, which for a large
`blob` is the dominant cost of encoding it. Making this the caller's decision puts it where
the knowledge is: only the caller knows what its sink does with what it is handed.)*

See §6 for the full list of write operations (typed scalars, arrays, sequence framing).

### 5.2 Streaming Deserialization (Decoder)

The decoder uses a **push-feed / pull-read** model:

* **Push:** the caller feeds raw bytes in arbitrarily small chunks. A single field
  header or payload may be split across many feed calls; the decoder's internal state
  machine suspends and resumes at **any** byte boundary without losing state.
* **Event:** as soon as a complete field header `(id, type)` is parsed, the decoder
  notifies the **field handler** — a callback, visitor, or iterator yield, depending
  on the language idiom — with the field's identity and type metadata.
* **Pull:** the handler decides what to do with the field:
  * **Read** the value into a typed destination (scalar, string, blob, or array).
  * **Descend** into a nested sequence using a child handler, which follows the same
    push-feed / pull-read pattern recursively.
  * **Skip** — do nothing; the field's remaining bytes, or the entire sub-sequence,
    are consumed and discarded automatically as subsequent chunks arrive.

This push/pull split is what makes true input-side streaming possible: the consumer
never has to hold the whole message, and it binds output storage lazily, per field.

**Decode outcome — a three-valued status, no finalize step (normative).** Decoding
is incremental: a chunk boundary may fall **anywhere**, including mid-field. Every
`feed` — and the one-shot `decode`, which is just a single `feed` of the whole
input — returns one of exactly three outcomes describing the bytes consumed *so
far*:

| outcome | one-shot alias | meaning | can more bytes change it? |
|---|---|---|---|
| **`COMPLETE`** | `OK` | the consumed bytes end **exactly** at a field boundary; a valid message *may* end here (more fields may also still follow) | more valid fields may extend it |
| **`INCOMPLETE`** | `OK_BUT_INCOMPLETE` | the bytes end **inside** a field — an unterminated varint (§4.1: the `0x80` continuation flag was set but the stream stopped), a fixlen payload (§4.6) shorter than its declared length, or inside a sequence not yet closed; the partial tail is retained for the next `feed` | **yes** — feeding more bytes may complete it |
| **`INVALID`** | `ERROR` | the bytes are malformed **regardless of what follows**: a reserved fixlen subtype (`0x4`–`0x7`, §4.6), a fixlen `fp32`/`fp64` whose declared length is not exactly 4 / 8 (§4.6), a varint exceeding 64 bits (§4.1), an **id**, length or count above its maximum (§6.2), nesting past `MAX_DEPTH` (§4.9), a sequence-end marker with no open sequence, or an invalid-UTF-8 `string` payload when the strict UTF-8 check is enabled (§6.4) | no — terminal |

**`INCOMPLETE` is explicitly NOT an error — it is a valid, first-class outcome**,
returned the same way from a one-shot `decode` and a streaming `feed`. A conformant
decoder **MUST** report it distinctly and **MUST NOT** fold it into either
neighbour:

* folding `INCOMPLETE` into `COMPLETE` (silently treating a truncated tail as a
  finished message) is non-conformant;
* folding `INCOMPLETE` into `INVALID` (rejecting a stream that was merely split
  across chunks, or a prefix the caller may still extend) is non-conformant.

**Precedence — `INVALID` wins over `INCOMPLETE` (normative).** The two
non-`COMPLETE` outcomes are not symmetric. When the bytes consumed so far
contain a construct that is malformed **independently of any bytes that might
follow** — any of the table's `INVALID` conditions: a reserved fixlen subtype,
an overlong varint, a wrong-width `fp32`/`fp64` fixlen (§4.6), an over-maximum id,
length or count, nesting past `MAX_DEPTH`, a sequence-end with no open
sequence — the outcome is **`INVALID`**, even if the input is *also* truncated
(ends mid-field or with an open sequence). `INCOMPLETE` is reported **only**
when every construct consumed so far is well-formed and the bytes simply end
before the message does; a decoder **MUST NOT** report `INCOMPLETE` for input
it has already determined to be malformed. No continuation of bytes can make
such input valid, so `INCOMPLETE` would wrongly invite the caller to feed more.
(This does not conflict with the anti-folding rule above: a well-formed prefix
that is merely truncated stays `INCOMPLETE`; only genuinely malformed input is
`INVALID`.)

Consequently, a decoder **MUST** validate a construct's well-formedness at the
point its describing bytes are read — the field header, `fixlen_word`, or
count — before consuming, buffering, or waiting for the payload those bytes
describe. A decoder that defers the check until the payload has arrived can
reach end-of-input first and mis-report malformed input as `INCOMPLETE`.
(Example: `56 0a 59` — a nested `fp64` field whose `fixlen_word` declares
length 11 ≠ 8, then truncates. The `fixlen_word` alone proves the message
malformed, so the outcome is `INVALID`, not `INCOMPLETE`.)

**No finalization step — the caller owns end-of-input.** The three outcomes are a
property of the bytes consumed so far and are computable at **any** byte boundary
from the decoder's own state. A decoder therefore needs **no** separate
`finish`/`finalize`/`end` step, and **MUST NOT** provide one that reclassifies
`INCOMPLETE` as `INVALID`. There is no hidden finalization: the status
`feed`/`decode` returns *is* the answer. Whether an `INCOMPLETE` result is
acceptable is the **caller's** decision, not the decoder's — only the caller knows
its framing:

* a **streaming** caller reads `INCOMPLETE` as "feed me the next chunk";
* a caller with an **outer frame** (a length prefix, a datagram boundary, EOF)
  that has delivered all its bytes and still sees `INCOMPLETE` knows the message
  was **truncated** and treats that as an error **at its own layer**;
* a **one-shot** caller that requires a whole message inspects the status and
  accepts only `COMPLETE`, treating `INCOMPLETE` (and `INVALID`) as failure.

The **framing invariant**, expressed purely through the returned status: a valid,
whole message is consumed **exactly** — it returns `COMPLETE` with nothing left
pending. Truncation (bytes short of a complete field) returns `INCOMPLETE`;
trailing bytes that *begin* but do not finish another field also return
`INCOMPLETE`; trailing bytes that cannot begin any valid field return `INVALID`.
A lone dangling `0x80` fed on its own returns **`INCOMPLETE`** (not `INVALID`): it
is a well-formed *prefix* of a varint, and more bytes could complete it. The
decoder never decides on the caller's behalf that this prefix is "truncated" — it
reports `INCOMPLETE` and lets the caller's framing rule. (Generated code passes
this status through verbatim — MESSAGE_SPEC §7.)

### 5.3 Language-Idiomatic Patterns (encouraged)

A new implementation **should use the best idiomatic pattern for its language** as long
as the wire bytes and the streaming guarantees are preserved. Proven mappings:

* **Visitor pattern *(preferred for object-capable languages)*:** the decoder calls
  typed visitor methods on a user-supplied object. Pull-reading becomes "the visitor
  writes the decoded value into one of the object's own members and chooses to skip
  anything it does not recognise". This is the **recommended choice** for any language
  that supports objects, classes, or structs, because the primary consumer of this
  library is *generated code* — objects or classes whose members directly mirror the
  schema fields. Those objects already exist at decode time; the visitor pattern lets
  the decoder write each field straight into the waiting member without an intermediate
  representation.
* **Pull-parser / iterator:** expose an iterator or `next()`-style API that yields
  field events; the caller pulls fields and reads or skips them. A reasonable
  alternative for languages or use-cases where a pre-existing target object is not
  available.
* **Flush callback / writer sink:** for the encoder, model the flush as a closure,
  a stream/writer sink, or an iterator of byte chunks — whichever the language prefers.
* **Heap-free / no-alloc build** where the language can target embedded or bare-metal
  systems; otherwise keep the hot path allocation-free.
* **Feature flags / build options:** disable fixlen, fp64, array, or sequence support,
  and integer-overflow checks, to shrink footprint for constrained targets.
* **Native-acceleration readiness** for scripting or interpreted languages: a
  pure-language implementation is a valid starting point, but isolate the hot-path
  primitives — varint encode/decode, buffer operations, field-header parsing — behind
  internal helpers. This makes it possible to swap those helpers for a native extension
  later **without changing the public API**. The upgrade must be invisible to callers:
  same names, same argument shapes, same return types.

Keep the **public API surface and naming reasonably parallel** across languages
(encode/decode, sequence begin/end, read/skip) so users moving between languages
stay oriented — see the existing ports for examples.

---

## 6. Language-Independent API Contract

A conforming `corelib-<lang>` must expose at least the following capabilities. Names
should be adapted to the language's conventions; semantics are fixed.

**Namespace and package name**
* All public symbols live under the `sofab` namespace (or the closest equivalent the
  target language offers — a package, module, crate, class prefix, or C-style name
  prefix). The namespace name is fixed: `sofab`. Do not shorten, abbreviate, or
  language-case it (e.g. not `SofaB`, not `Sofab`, not `sofabuffers`).
* The **package name** (as registered with the language's package manager / registry —
  e.g. crates.io, PyPI, npm, Maven Central) is `SofaBuffers`. This is the name users
  type in their dependency manifest (`Cargo.toml`, `pyproject.toml`, `package.json`,
  etc.). The package name and the namespace name are intentionally different: users
  install `SofaBuffers` but import / use `sofab`.

**API version**
* Expose a constant or getter that returns the integer API version (currently `1`).
  Callers and the generator use this to verify compatibility at build or runtime.

**Encoder**
* Initialize with an output sink (buffer + flush, or a stream/writer).
* A **write** operation covering all scalar types: unsigned integer, signed integer,
  boolean, fp32, fp64 *(optional/feature-gated)*, string (UTF-8, no null terminator on
  wire), and blob. **Boolean has no wire type** — the corelib's boolean write/read
  functions map it to/from an unsigned integer `0`/`1` (see §4.4). If the language
  supports overloading, a single `write(id, value)` dispatches on the value type;
  otherwise use `write_<type>(id, value)` variants.
* Array write covering unsigned-integer arrays, signed-integer arrays, and
  fixlen (fp32/fp64) arrays. Same overloading rule applies.
* **Sequence framing.** Opening and closing nested scopes, in a form that lets the
  message layer omit an all-default sequence **without buffering the message** —
  see the contract below.
* `flush()` and the ability to swap in a new output buffer mid-stream.

**Decoder**
* Initialize with a field handler (callback / visitor / pull-iterator).
* `feed(bytes)` accepting arbitrarily small chunks, returning the three-valued decode
  outcome `COMPLETE` / `INCOMPLETE` / `INVALID` (§5.2). **No** separate
  `finish`/`finalize`/`end` step — `INCOMPLETE` is surfaced to the caller, never
  auto-promoted to an error.
* **Chunk lifetime (normative).** A fed chunk is borrowed **only for the duration of the
  `feed` call**: once `feed` returns, the caller may reuse, overwrite or free that memory,
  and the decoded message **MUST NOT** be affected. A decoder that hands a `string`/`blob`
  destination a slice into a fed chunk therefore has to copy out of it before returning —
  as it already must for a payload split across chunks, which has no single chunk to point
  at. The **one-shot** `decode(buffer)` is exempt in the obvious way: the caller supplies
  the whole buffer and keeps it alive across the call, so a zero-copy view into *that*
  buffer stays valid for as long as the buffer does, and ports that offer one say so
  (§9.6).

  Without this rule the caller's obligation depends on where the chunk boundaries happened
  to fall — a payload arriving whole in one chunk could be borrowed while the same payload
  split across two is copied — so the *same message over a different chunking* would place
  different lifetime requirements on the same calling code. That is the class §6.4 and
  §7.2 item 4 already forbid for the decode outcome; memory obligations deserve the same
  answer.
* Per-field: **read** the value into a typed destination, or **skip**. If the language
  supports overloading a single `read(destination)` suffices; otherwise use
  `read_<type>(destination)` variants.
* Descend into nested sequences with a child handler (e.g. `read_sequence`); auto-skip
  of unread fields and whole sub-sequences.

#### Sequence framing: `begin_lazy` / `end` / `end_keep` (normative outcome)

MESSAGE_SPEC §2 omits a sequence-typed **field** whose value equals its declared
default, and keeps the frame of a wrapper-array **element** that is all-default.
Both are decided by *what the children turn out to be*, while the sequence header
has to be on the wire **before** them — so a naive encoder would have to buffer the
sub-message to find out. It does not have to. The obligation on a corelib is the
**outcome**, and the shape below is the one that meets it in a single forward pass:

* **`sequence_begin_lazy(id)`** — opens a scope and **holds the header back**. The
  ids of the innermost open sequences form a pending run.
* **any field write** — first emits the whole pending run, outermost header first,
  then the field. Writing content is what proves every enclosing sequence non-default.
* **`sequence_end()`** — if this sequence's header is still held back it received no
  content: **drop it**, header and end marker both. Otherwise emit `0x07`.
* **`sequence_end_keep()`** — behaves like a write: emit the pending run *and* the
  end marker, so a sequence that got no content still reaches the wire as
  `begin` + `end`.

The choice between the two closers is **static** — a property of the position in the
schema, not of the value, so generated code decides it at generation time:

| position | closer |
|---|---|
| `struct` / `union` field | `end` |
| array field (the wrapper) | `end` |
| wrapper-array **element** (`struct`/`union`/nested row) | `end_keep` |
| array field already known to differ from a **non-empty** declared `default` | `end_keep` |

The two failure directions are not symmetric, which makes `end_keep` the safe
default: using it where `end` would do costs one non-canonical empty frame that a
decoder normalizes away (MESSAGE_SPEC §2), while the reverse drops an element and
silently changes an array's **length** (§5.1).

Holding a header back never changes the bytes: the pending ids are encoder state,
not buffer content, so a flush cannot split a pending run and an output buffer
smaller than the message produces exactly the one-shot bytes (§5.1, §7.2).

**This is a recommended shape, not a mandated API.** What every implementation
**MUST** produce is the canonical encoding of MESSAGE_SPEC §2. An implementation
whose message layer is a **descriptor/object table** — it can test each field
against its default *before* opening anything, as the C reference does in
`sofab_object_encode` — meets the obligation with the plain eager
`sequence_begin` / `sequence_end` pair and needs none of the above. The hold-back
trio exists for the other case: when the message layer is **generated code**, the
predicate is spread across dozens of individual write calls and the output stream is
the only place that sees them all.

A profile that exposes the trio only for its generated-code consumers **MAY** make
it a build option (the C reference gates it behind `SOFAB_DISABLE_LAZY_SEQ_SUPPORT`,
which removes the pending array from the stream context). Note that such a switch
changes the context layout and must therefore be configured identically for the
library and everything that includes it.

**How deep the hold-back reaches (normative).** The pending run grows with nesting,
so an implementation that can allocate **MUST** hold back to the full `MAX_DEPTH`
(§6.2) and is thereby canonical at every depth. A **heap-free profile** cannot: it
**MAY** bound the run to a fixed depth, and beyond that bound it frames eagerly —
emitting the empty frame that §2 would have omitted. That output is **well-formed
and decodes to the same value** (it is the non-canonical form §2 already requires
every decoder to accept and normalize), so the two profiles interoperate; what it
is not is canonical. This is the same constrained-profile allowance `FIXLEN_MAX`
and `ARRAY_MAX` already carry (§6.2), and it exists for the same reason: a bound
that costs RAM per stream is a real cost on a target that has none to spare. A
profile that takes it **MUST** document the bound, because two encoders that
disagree about it disagree about bytes — not about validity.

### 6.1 Two Audiences: Direct corelib Use vs. Generated Objects

A corelib has **two** kinds of users, and the API must serve both:

1. **Direct use (the power-user path).** A developer calls the raw encoder/decoder
   from §5–§6 by hand, choosing field IDs and read/write calls themselves. This is
   fully supported and is the right choice for tiny embedded messages or one-off
   wire work.

2. **Generated objects (the normal path).** In the common case the developer never
   touches the raw API. Instead the **`generator`** turns a language-neutral
   **object description** (the schema) into ready-made **objects / classes /
   structs in the target language**. The developer just uses those generated types.

> **Architectural hint:** design the corelib so that a *thin* generated layer can sit
> on top of it. The generated objects are the product most humans interact with, so
> **their API must be extremely simple** — while the corelib underneath must still
> expose enough hooks that those same objects can be serialized and deserialized **in
> chunks**.

**Generated-object API must be dead simple.** A human using a generated `Person`
object should think in terms of *fields, encode and decode*, never in terms of
varints, field IDs, sequence markers, or buffers. Target roughly this ergonomics
(names adapted to the language's casing, see §6.1.1):

```
person = Person()           # plain typed fields: person.name, person.age, person.tags[]
person.name = "Ada"
person.age  = 36

bytes   = person.encode()               # one-shot convenience
person2 = Person.decode(bytes)          # one-shot convenience
```

* Generated fields are ordinary typed members with language-natural accessors;
  IDs/types/order come from the schema and are hidden inside the generated code.
* Nested schema messages become nested generated objects; repeated fields become the
  language's natural list/array type.
* Provide one-line `encode()` / `decode()` convenience methods for the
  90% case (message fits comfortably in memory).

**But generated objects must ALSO stream in chunks.** The convenience methods are
just shortcuts; every generated object must additionally accept an incremental path so
large objects never force a full in-memory buffer:

```
# streaming OUT: feed an existing ostream / sink; bytes leave as the buffer fills
person.serialize(ostream)               # writes via the corelib flush callback / sink

# streaming IN: drive a decoder fed with arbitrarily small chunks
dec = Person.decoder()                  # a generated reader bound to the corelib istream
st = dec.feed(chunk1); st = dec.feed(chunk2); ...  # each feed returns COMPLETE / INCOMPLETE / INVALID
person = dec.value                      # object assembled incrementally, never fully buffered
# No finish()/end(): `st` is the outcome so far. The caller accepts `person` once
# st == COMPLETE and its framing says the input is done; a still-INCOMPLETE status at
# end-of-input is truncation, judged by the caller (§5.2).
```

**This forces a requirement back onto the corelib API:** the generated layer must be
buildable purely from the streaming primitives. Concretely, the corelib **must**:

* Let the generator drive encoding through the **same flush-callback / sink + buffer
  swap** mechanism (§5.1), so `serialize` works with an output buffer smaller than
  the object.
* Let the generator drive decoding through the **push-feed + pull-read / visitor**
  mechanism (§5.2), so a generated decoder can consume **arbitrarily small `feed`
  chunks** and bind each decoded field straight into the object's member — including
  descending into nested generated objects via `read_sequence` and resuming a
  half-built object across chunk boundaries.
#### 6.1.1 Canonical names for the generated-object layer (normative)

Generated types land in the **user's** namespace, and every extra spelling a port
invents — `serialize_to`, `to_bytes`, `from_bytes`, `decode_from`, `decode_into`,
`marshal`, `unmarshal` — is one more name a developer has to learn per language for
an operation that is identical everywhere. The set is therefore closed. Adapt only
the **casing/idiom** (`try_decode` / `tryDecode` / `TryDecode`), never the words.

Two pairs, split by who the caller is:

| name | kind | purpose |
|---|---|---|
| `encode()` | instance | one-shot: produce the complete message as bytes |
| `decode(bytes)` | static / free | one-shot: build the object from a complete message; fails only in the language's own way (exception / panic-free variant below) |
| `try_decode(bytes)` | static / free | the fallible form of `decode` for languages that return results rather than throw; returns the object or the §6.3 error |
| `serialize(ostream)` | instance | streaming out: write the object's fields into a corelib output stream (§5.1) |
| `deserialize(istream, …)` | instance | streaming in: the per-field hook the corelib's decoder calls (visitor/callback, §5.2) |
| `decoder()` | static / free | streaming in: obtain the generated reader that `feed`s arbitrarily small chunks |

`encode` / `decode` are the **convenience** layer users reach for; `serialize` /
`deserialize` are the **streaming** pair that talks to the corelib, and the
convenience pair is a thin wrapper over it (§6.1). A port **MUST NOT** add a second
name for either — no `serialize_to` alongside `serialize`, no `from_bytes` alongside
`decode`. Language-mandated extras stay allowed where the ecosystem requires them
(a `Display`/`ToString`, a serde/`IXmlSerializable` bridge, an idiomatic constructor);
they are not alternative entry points into the wire format.

Anything below this layer — `feed`, `read_*`, `write_*`, `sequence_*` — is corelib
API (§6) and keeps its own names; it is not part of the generated object's surface.

### 6.2 Limits & Constants (normative)

| Constant | Value |
|----------|-------|
| `API_VERSION` | `1` |
| `ID_MAX` | 2,147,483,647 (2³¹ − 1) |
| Field ID range | 0 .. 2,147,483,647 |
| Unsigned value domain | 64-bit unsigned (0 .. 2⁶⁴ − 1) |
| Signed value domain | 64-bit signed (−2⁶³ .. 2⁶³ − 1) |
| `FIXLEN_MAX` | up to 2,147,483,647 (may be 65,535 on constrained profiles) |
| `ARRAY_MAX` | up to 2,147,483,647 (may be 65,535 on constrained profiles) |
| `MAX_DEPTH` | 255 (maximum nested-sequence depth) |
| Scalar value width | 64-bit by default |

These are **format-wide ceilings**: properties of the wire format itself, identical for
every implementation, and exceeding one is `INVALID` (§5.2). They are not a protection
mechanism against a hostile sender — that is §6.2.1.

`ID_MAX` and the `Field ID range` bind the id of **every** field header, without
exception: the value-bearing ones — unsigned, signed, fixlen, the array types and
sequence *start* — and the **sequence-end** marker alike. That a sequence end's id is
discarded rather than used (§4.9) does not exempt it. The ceiling is stated over
headers, not over headers whose id a decoder happens to consult, and keeping it uniform
is what lets an implementation validate the id where it decodes the header — one
unconditional comparison — instead of carrying a per-wire-type exception through every
decode surface.

#### 6.2.1 Receiver-side technical limits (normative)

A field whose schema declares no bound (`maxlen`/`count` omitted — MESSAGE_SPEC §7.2) is
**unbounded**: the receiver allocates whatever the message specifies. That lets the
**sender** dictate the **receiver's** allocation, so an implementation **MAY** be
configured with **generic maximum limits** — capping the array count, string length and
blob length it will materialize (e.g. `max_dyn_array_count`, `max_dyn_string_len`,
`max_dyn_blob_len`).

These limits are **configuration, not schema**:

* They are chosen by the **implementer/deployment** to protect the system, **independent
  of any message definition**, and are **not** part of the wire contract.
* Exceeding one is a **policy rejection by the receiver — a category distinct from
  `INVALID`**. The bytes are well-formed and decode successfully under a looser or unset
  limit; nothing about the *message* is malformed. An implementation **MUST NOT** report
  it as `InvalidMessage`, and **MUST NOT** fold it into the `INVALID` decode outcome.
* They **MUST NOT** be applied to a field the schema already bounds. There the schema
  bound governs and its violation is `INVALID` (MESSAGE_SPEC §7, §7.1) — a schema bound is
  a statement about *validity*, a receiver limit is a statement about *capacity*.
* Two receivers configured with **different** limits reaching different outcomes on the
  same message is **not** an interop failure and **not** a conformance defect. Conformance
  testing therefore compares implementations configured with **identical** limits.

A limit **MUST** be enforced at the count/length header — before the allocation it is
meant to prevent — for the same reason `INVALID` is decided there (§5.2).

*(This is the receiver-capacity analogue of the `MAX_DEPTH` stack bound: both cap what the
receiver will commit on untrusted input. `MAX_DEPTH` is a fixed format-wide ceiling and its
violation is malformed input; a `max_dyn_*` limit is deployment-configurable and its
violation is not.)*

### 6.3 Error Handling (normative)

Every fallible operation reports one of the following result codes. The names below are
canonical; adapt them to the language's casing/idioms, but keep the meanings fixed. (The
C/C++ reference exposes these as the `sofab_ret_t` codes / the `Error` enum.)

| Code | Meaning |
|------|---------|
| `None` / `OK` | Success. |
| `BufferFull` | Output buffer overflowed during encoding. |
| `InvalidArgument` | Invalid argument — a field ID out of range, a scalar width that is not 1/2/4/8 bytes, a descriptor field type that does not exist — or, with the strict UTF-8 check ON (§6.4), a `string` value that cannot be encoded as valid UTF-8 (non-UTF-8 bytes, an unpaired surrogate). |
| `InvalidMessage` | Malformed message while decoding — malformed **regardless of what follows**: an **overlong (`>64`-bit) varint**, an unbalanced sequence end, an oversized length/count, nesting past `MAX_DEPTH`, a reserved fixlen subtype, a wrong-width `fp32`/`fp64` fixlen (§4.6), or an invalid-UTF-8 `string` **when the UTF-8 check is enabled** (§6.4). Corresponds to the `INVALID` decode outcome (§5.2). **Truncation is _not_ `InvalidMessage`** — see the note below — but input that is *both* malformed and truncated *is*: `INVALID` takes precedence over `INCOMPLETE` (§5.2). |
| `LimitExceeded` | A configured **receiver-side technical limit** (§6.2.1) was exceeded on a schema-**unbounded** field — e.g. `max_dyn_array_count` / `max_dyn_string_len` / `max_dyn_blob_len`. The message is **well-formed**: the same bytes decode successfully under a looser or unset limit, so this says nothing about the message's validity and is **not** `InvalidMessage` and **not** the `INVALID` decode outcome (§5.2). It is a terminal, receiver-local **policy** rejection. Never raised for a field the schema bounds — there an over-bound value is `InvalidMessage` (MESSAGE_SPEC §7, §7.1). |

**Decode outcome vs. error code.** A decoder's per-`feed`/`decode` result is the
three-valued **decode outcome** `COMPLETE` / `INCOMPLETE` / `INVALID` (§5.2),
*not* one of the codes in this table. `INVALID` corresponds to
`InvalidMessage`; **`INCOMPLETE`** — bytes short of a complete field, i.e. truncation —
is **not** an error and **must not** be reported as `InvalidMessage`: it is surfaced to
the caller, who judges it per its own framing. There is **no** `finish`/`finalize` step
that turns an `INCOMPLETE` into `InvalidMessage`. The codes in this table cover the
*other* fallible operations (encoding, argument checks).

**A type-mismatched read is not an error at all.** Binding a read whose declared type
contradicts the field on the wire is the MESSAGE_SPEC §7.3 case: the field **MUST** be
skipped like an unknown id, leaving the destination untouched — it is neither
`InvalidMessage` nor an argument error, and a decode that meets nothing else stays
`COMPLETE`. There is therefore **no** result code for "invalid usage": every remaining
caller mistake is an out-of-range argument (`InvalidArgument`) and every remaining
malformed input is `InvalidMessage`.

**`LimitExceeded` is the one decode-path exception to that split.** A configured
receiver-side limit (§6.2.1) terminates a decode, but the input is *well-formed*, so the
outcome is **not** `INVALID` — and the three-valued outcome has no value for "valid, but
more than I am configured to accept". An implementation **MUST** keep the two
distinguishable to the caller (a limit rejection means *"raise my limit or the sender must
send less"*; `INVALID` means *"these bytes are broken"*). **How** it is surfaced is an API
shape this document deliberately leaves open: either as a **fourth decode outcome**
alongside `COMPLETE`/`INCOMPLETE`/`INVALID`, or as a terminal failure carrying the
`LimitExceeded` code on the error channel. Whichever an implementation picks, it **MUST
NOT** report a limit rejection as `InvalidMessage`.

This set is the common baseline. **Language- or platform-specific conditions may extend
or refine it** — e.g. an I/O error from a stream sink, an allocation failure in a managed
runtime, or an encoding error raised by a particular standard library. Such extra cases
are allowed as long as the baseline meanings above are preserved.

**Exceptions vs. return codes:**

* In languages where exceptions are the **default, idiomatic** error mechanism
  (e.g. Python, Java, C#), throwing is fine — map the codes above onto exception types.
* In languages where exceptions are **unavailable, costly, or commonly forbidden**
  (e.g. C, embedded / `no_std`, real-time or kernel targets, or a `-fno-exceptions`
  build), **do not use exceptions.** Return a status code or a result/`Result`-style
  object on the hot path instead, so callers in constrained environments are never forced
  to pay for or handle exceptions.

### 6.4 String Validity: UTF-8 (`SOFAB_STRICT_UTF8`, normative)

A `string` payload is **UTF-8** (§4.6); `blob` is the type for opaque byte
sequences (the producer-side rule lives in MESSAGE_SPEC §8). A `string` payload
whose bytes are **not valid UTF-8** is a malformed string: the strict,
conformant behavior is to reject it — on decode as the `INVALID` outcome
(§5.2), on encode as `InvalidArgument` (§6.3).

UTF-8 validation is gated behind one canonical configuration option,
**`SOFAB_STRICT_UTF8`** (adapt the name to the language's casing/idiom). It is
a **validation policy, never a wire-format switch**: it only decides
accept-vs-reject and never changes how valid data is encoded, so two peers with
different settings interoperate on all valid data.

**Two states:**

* **ON (default)** — invalid UTF-8 is rejected, **symmetrically**:
  * *decode*: an invalid-UTF-8 `string` payload **that is read** is the
    `INVALID` outcome (§5.2) — the same terminal class as the other
    malformed-message conditions, *not* a length/limit error. Skipped fields
    are never validated (below).
  * *encode*: a `string` value that cannot be encoded as valid UTF-8 —
    non-UTF-8 bytes in a byte-container type, an **unpaired surrogate** in a
    UTF-16/Unicode type — is refused with `InvalidArgument` (§6.3). Encode-side
    validation is what enforces MESSAGE_SPEC §8's producer-side **MUST NOT**:
    without it, a strict ecosystem's own encoders can still emit bytes its
    decoders reject.
* **OFF (opt-out)** — validation is waived, but the permitted behavior is
  pinned, not implementation-defined: **raw or reject, never silent lossy**
  (next paragraph).

**OFF is constrained (normative).** With the check OFF, handling follows the
language's native string representation, and only two behaviors are permitted:

* **Byte-container string types** (C `char[]`, C++ `std::string`, Go `string`,
  Zig `[]const u8`) store the wire bytes **verbatim** — no transcoding,
  zero-copy allowed. Interpreting code points is the application's job.
* **Unicode string types** (Rust `String`, Java/C# `string`, JavaScript
  strings, Python `str`) cannot hold non-UTF-8 bytes; their only non-mutating
  option is the **strict / fatal** constructor, so they are **always strict**.
  For them the option is a no-op and they **MAY omit it entirely** (documented
  as always-ON); only **byte-container targets MUST expose it**.

**Silent replacement is forbidden in every mode (normative).** An
implementation **MUST NOT** substitute `U+FFFD` (or any replacement), drop
bytes, or produce an empty/absent value for an invalid-UTF-8 `string`, in
either direction, in any mode (MESSAGE_SPEC §8). Beware that platform default
encoders are often lossy — Java's `getBytes(UTF_8)` and JavaScript's
`TextEncoder` replace unpaired surrogates with `U+FFFD` — use the strict/fatal
variants.

**Default.** `SOFAB_STRICT_UTF8` defaults to **ON**, making the default
configuration the same configuration the shared vectors (§7.1) and the
differential fuzzer test. For Unicode-string targets strictness is already paid
for by the mandatory transcode; for byte-container targets a proper validator
is cheap next to decode itself. **Constrained/footprint profiles MAY default to
OFF or compile the check out entirely** (zero `.text`/`.rodata` cost when OFF) —
the same profile allowance as `FIXLEN_MAX`/`ARRAY_MAX` (§6.2). Such a build is
a documented non-strict build; the target's CI **MUST** still build and
conformance-test the check-ON configuration.

**Where the knob lives** (byte-container targets) follows where the corelib
already keeps its configuration:

* *compile-time* (C `#define`, a Zig build feature) — for footprint targets;
  compiled OFF means the validation code is not compiled in.
* *runtime option* (a decoder/encoder configuration field, e.g. in Go) — slots
  next to the existing decode limits. C++ may use either, per its existing
  configuration style.

**The `utf8_valid` primitive.** Where generated code — not the corelib —
materializes the string in a **byte-container** target (Zig), the corelib
exposes a `utf8_valid(bytes) -> bool` primitive and the generator emits an
**unconditional** call to it. The gate lives inside the primitive: it folds to
`true` when compiled OFF and reads the runtime option otherwise. Flipping the
flag therefore never requires regenerating code, and generated code is
identical across build configurations. (In codegen-materialized
Unicode-string targets — Rust, Java, C# — generated code simply uses the
strict constructor; no primitive is needed.)

**Validator correctness (normative).** `utf8_valid` — and any corelib-internal
check — is a real UTF-8 validator, not a byte-range shortcut; this is a
security surface. It **MUST** reject overlong encodings (including `C0 80`,
Java's "Modified UTF-8" NUL), surrogate code points `U+D800`–`U+DFFF`, and code
points above `U+10FFFF`. Most languages have a stdlib validator to gate; C and
C++ need a hand-written, tested one.

**Embedded U+0000 is allowed.** NUL is valid UTF-8 and representable in the
length-framed payload (§4.6); the validator **MUST NOT** reject it, while the
overlong form `C0 80` **MUST** be rejected like any overlong encoding. Interop
note (non-normative): NUL-terminated consumers truncate at the first NUL — the
corelib API is length-delimited (§4.6), but producers targeting such consumers
SHOULD avoid embedded NUL or use `blob` (MESSAGE_SPEC §8).

**Cross-chunk semantics (normative).** UTF-8 validity is a property of the
string field's **complete payload** — the fixlen length is known up front — and
a chunk boundary **MUST NOT** affect the outcome. A decoder MAY validate
incrementally, provided it carries validator state across `feed` calls; no
assembly buffer is required. The outcome mapping follows §5.2:

* a multi-byte sequence split at an **end-of-chunk** is a well-formed prefix →
  `INCOMPLETE` (more bytes may complete it). Reporting `INVALID` — or dropping
  the string — for a merely-split payload is the §5.2 anti-folding violation;
* a multi-byte sequence truncated at **end-of-payload** (declared length
  reached mid-sequence) → `INVALID`: no further bytes belong to this string;
* a byte that cannot begin or continue any valid sequence (e.g. `0xFF`, a bare
  continuation byte) is malformed regardless of what follows — but the verdict is
  still reported **at payload completion**, not before. A decoder **MUST NOT**
  report `INVALID` mid-payload for such a byte while the declared length has not
  been reached; that input is `INCOMPLETE` until the payload ends, and `INVALID`
  once it does.

  This is the one place where §5.2's INVALID-dominates-INCOMPLETE precedence does
  *not* pull the verdict forward, and the reason is that this check is not a
  property of the wire. `SOFAB_STRICT_UTF8` has a normative OFF mode in which the
  same bytes are accepted, and validation runs only where a `string` is
  **materialized**, never on skip — so the same payload is already valid or invalid
  depending on a build flag and on whether the handler read it. Letting its
  *timing* decide the verdict as well would make two conformant decoders disagree
  on accept-vs-reject, which is exactly what MESSAGE_SPEC §7.1 forbids and what
  this section's own opening sentence promises a chunk boundary cannot do.

**Skipped fields are never validated (normative).** Skipping stays what it is
everywhere else in the design: a length jump over bytes that are not
inspected (§5.2). UTF-8 validation runs only where a `string` is
**materialized** — read into a destination — never on skip, in any mode.
Wire validity of unread content is the **producer's** responsibility
(MESSAGE_SPEC §8's MUST NOT, enforced by the strict encode side); protobuf
treats unknown/unread fields the same way. The decode outcome may therefore
depend on which fields the handler reads; the shared vectors and the
differential-fuzzer drivers read **every** field, so conformance results
remain deterministic.

**Conformance testing and the SofaBuffers differential fuzzer run with the
check ON** — which is also the shipped default — so every implementation agrees
that an invalid-UTF-8 `string` is rejected. A deployment that needs maximum
decode throughput and controls both ends may switch it off; cross-implementation
interop requires it on.

### 6.5 Float Bit-Exactness: the fp32 signaling-NaN hazard (normative)

§4.6 requires every float — `NaN` included — to round-trip **bit-for-bit**: the
corelib never inspects or normalizes a float payload. For `fp64` this is free —
a language's native 64-bit double holds all 64 bits verbatim. **`fp32` carries a
representation hazard that several languages fall into, and this section makes
the guard against it normative.**

**The hazard.** IEEE-754 distinguishes two kinds of `NaN` by the most-significant
mantissa bit (the *quiet* bit): a **quiet** NaN has it set, a **signaling** NaN
has it clear (with a non-zero payload). Widening an `fp32` to a wider float is
**not** bit-preserving for a signaling NaN — the IEEE `fp32 → fp64` widening
**sets the quiet bit**, converting an `fp32` sNaN into a qNaN:

```
fp32 sNaN   0x7F80_0001   ── widen to double ──▶   qNaN   0x7FC0_0001
                    ▲ quiet bit 0 (signaling)               ▲ quiet bit 1 (quiet)
```

The sNaN payload is destroyed **the instant the value passes through the wider
float**, and no later code can recover it — the bits are simply gone. If a
decoder carries an `fp32` payload to the consumer (or to its own re-encode) as a
widened double, then a decode → re-encode **loses the sNaN** and the wire bytes
change — a §4.6 violation.

**Which implementations must act — and which need do nothing.** The extra
handling in this section is required **only** where the language has **no native
`fp32` value type** and must represent every `fp32` as a 64-bit double, so any
`fp32` handed to user/generated code is *already* widened and the sNaN is
*already* gone:

* **JavaScript / TypeScript** — every `number` is a double; there is no `fp32`
  value type.
* **Python** — `float` is a double.
* **Dart** — the only floating type is `double`.
* **Lua** (default build), and any other language whose sole float value is a
  double, or that materializes `fp32` only by first widening it.

**Languages with a real `fp32` type need no special handling — nothing to do.**
Where the target has a native, non-widening 32-bit float (`f32` / `float` in
Rust, C, C++, Go, Java, C#, Zig), the natural implementation already keeps the
payload in that `fp32` type end-to-end — a plain 4-byte load/store, no `fp64` in
the round-trip path — so a signaling NaN round-trips bit-for-bit **on its own**.
Such a target satisfies §4.6 for free; the raw-bytes channel below is neither
required nor needed. (The only thing to avoid is *gratuitously* widening an
`fp32` to a `double` and back, which no idiomatic `fp32`-typed implementation
does anyway.)

**Requirement (normative).** The §4.6 outcome is universal — for **every**
implementation, decode → re-encode of any `fp32` payload (signaling NaN
included) **MUST** reproduce the exact 4 wire bytes, at **every** `fp32`
position: a **scalar** `fp32` (§4.6) **and** each element of an **`fp32` array**
(§4.8). What differs is only *how* a target meets it:

* **Native-`fp32` targets** meet it **for free** (above): no raw channel, no
  extra code.
* **Double-only targets** cannot meet it through the widened value, so they
  **MUST** provide a **raw-wire-bytes** path for bit-exact consumers (transcode,
  round-trip, any re-encode) that re-emits those bytes **verbatim** — and **MUST
  NOT** re-encode an `fp32` from the widened value. The convenience **value**
  handed to a value consumer **MAY** stay a widened double — it only needs to
  know the value is `NaN`.
* Either way this holds on **every** decode surface the implementation exposes —
  push / visitor, streaming, and pull / cursor alike (a guard added to one
  surface but not another is the recurring defect class this section exists to
  prevent).
* `fp64` never needs the raw path, in any language: a native double round-trips
  its own sNaN.

**How (double-only targets only).** Deliver the `fp32` payload the same way a
`string`/`blob` payload is delivered — as the raw little-endian wire bytes (a
zero-copy view or a 32-bit bits accessor) — *alongside* the convenience `value`,
and re-encode by writing those bytes directly (never `setFloat32` /
reinterpret-from-double). Gate the raw channel as opt-in if a per-element view
would burden value-only array decoding. (Native-`fp32` targets skip this
entirely.)

**Testing (normative).** Because the JSON test vectors cannot represent `NaN`
(§4.6, §7.1), this is verified by an **implementation-level** suite, not the
shared vectors: assert that a signaling, quiet, and negative `fp32` NaN each
round-trips **bit-for-bit** at both a scalar `fp32` position and an `fp32`-array
position, across decode → re-encode **and** any materialized walk, on **every**
decode surface. The SofaBuffers differential harness (Crucible) additionally
checks that all language drivers agree bit-for-bit on every `fp32` NaN.

---

## 7. Mandatory Unit Testing

Every `corelib-<lang>` **must** ship unit tests, and those tests **must** validate
against the shared, language-agnostic conformance suite. The test folder name follows
the language's idiomatic convention — `tests/` in Rust and Python,
`src/test/` in Java/C#, `<pkg>_test.go` files in Go, etc.

### 7.1 Use the Shared Test Vectors

* Copy **`test_vectors.json`** from `corelib-c-cpp` into the new repo's `assets/` folder
  (see §8); the test suite reads it from there. Do **not** hand-write a divergent copy —
  `corelib-c-cpp` **generates** these vectors and is their source of truth:
  <https://raw.githubusercontent.com/sofa-buffers/corelib-c-cpp/refs/heads/main/assets/test_vectors.json>
  The vector schema is documented alongside it in
  `corelib-c-cpp/assets/test_vectors_README.md`:
  <https://raw.githubusercontent.com/sofa-buffers/corelib-c-cpp/refs/heads/main/assets/test_vectors_README.md>
* For the file's structure — top-level keys, the per-vector fields, the full list of
  `fields[]` operations and their parameters, and how floats/blobs/offsets are
  represented — follow the authoritative `test_vectors_README.md` linked above rather
  than a copy here, so this plan can never drift from the generated format.
* Vector categories to cover: scalars (unsigned/signed/bool/fp32/fp64/string/blob);
  field-ID boundaries (`0` and `2,147,483,647`); **all three array wire types** —
  unsigned-integer arrays (`u8..u64`, type `0b011`), signed-integer arrays (`i8..i64`,
  type `0b100`), and fixlen/float arrays (`fp32`/`fp64`, type `0b101`) incl. special
  values (`±0`, `±inf`); sequences (nested, with scalars and arrays; structs and unions);
  and a large composite message mixing everything.

### 7.2 Required Test Kinds

1. **Vector encode test** — replay each vector's `fields` through your encoder at the
   given `offset`; assert the produced bytes equal `serialized.hex`.
2. **Vector decode test** — feed `serialized.hex` bytes into your decoder; assert the
   recovered fields/values match `fields`.
3. **Roundtrip tests** — encode → decode → compare for representative messages.
4. **Chunked-streaming tests** — the defining requirement:
   * **Encode** into a buffer of exactly **`MIN_OUTPUT_BUFFER`** bytes, driving the flush
     callback / sink repeatedly; assert the concatenated output is byte-identical to the
     one-shot output. The port's own declared minimum rather than merely "smaller than the
     message": it is the size that proves the constant is real, and for a port declaring `1`
     it is the same test as before — no write needs to land contiguously (§5.1). Cover a
     `string` or `blob` payload longer than the buffer, so the divisible-run path is
     exercised whatever the declared value is.
   * **Reject a buffer below the minimum** — install one **with a flush sink**, with
     `buflen - offset` one byte short of `MIN_OUTPUT_BUFFER`, and assert it fails **there**,
     by the port's own out-of-range mechanism, rather than partway through a message (§5.1).
     A port declaring `1` tests the zero-length buffer. Pair it with the converse: the same
     undersized buffer **without** a sink is accepted, and a message that fits encodes into
     it — the minimum is a streaming constant and must not become a floor on the one-shot
     path.
   * **Encode across a taking sink** — a flush callback that installs a *different* buffer
     on every call, scrubbing the one it was handed before returning; assert the
     concatenated output still equals the one-shot output. This is the zero-copy handover
     of §5.1: an encoder that kept writing into the buffer it gave away reads back the fill
     pattern, and the one-byte test above would not notice, since that sink copies and
     returns. Pair it with a **copying** sink that returns without installing anything and
     assert the same output, so both halves of the returning-callback contract are covered.
   * **No foreign memory without permission** — encode a `blob` several times the buffer
     size through a sink that was **not** granted pass-through, and assert every callback
     argument lies within the installed buffer (compare identity, or that the pointer falls
     inside it). A port that never passes through passes by construction; a port that does
     has one place to get the condition wrong, and this is it.
     Assert also that a sink granted pass-through which calls the
     buffer-set operation is **rejected** — the two are mutually exclusive (§5.1).
   * **Decode** by feeding the input **one byte at a time** (and in odd-sized chunks);
     assert the result is identical to feeding it all at once. This proves the state
     machine suspends/resumes at any byte boundary.
   * **Overwrite every chunk after `feed` returns** — scrub it with a fill byte, or free
     it — and assert the decoded message is unchanged. This is what makes the chunk
     lifetime of §6 a checked property rather than a stated one: a decoder that keeps a
     slice into a fed chunk reads back the fill pattern, and nothing else in this list
     would notice.
5. **Malformed-input tests** — an overlong (`>64`-bit) varint, an unbalanced sequence
   end, an oversized id/length/count, nesting past `MAX_DEPTH`, a reserved fixlen
   subtype (`0x4`–`0x7`) → must return the `INVALID` decode outcome (a well-defined
   error), never crash. Cover the oversized id on a **sequence-end** header too, not
   only on a value-bearing one: §6.2 admits no exception, and an implementation that
   validates the id only in the branches that *use* it will pass the value-bearing case
   and miss this one.
5b. **Tolerance tests** — input that is non-canonical but well-formed **MUST** decode to
   the value it denotes and re-encode canonically, never `INVALID`: a non-minimal varint
   (§4.1) at a field header, a `fixlen_word` and an element count; and a **sequence-end
   header whose id is non-zero but within `ID_MAX`** (§4.9), which must decode as an
   ordinary sequence end and re-encode as `0x07`. These are the cases where a decoder is
   *stricter* than the format allows — the mirror of the malformed-input tests above, and
   the ones a majority-vote conformance check cannot catch, since an implementation may
   be uniformly too strict.
6. **Truncation tests** — a message cut short mid-field (a lone dangling varint such as
   `0x80`, a fixlen payload shorter than its declared length, an unclosed sequence) →
   must return **`INCOMPLETE`**, *not* `INVALID` and *not* `COMPLETE`. It is a
   well-defined non-error outcome; feeding the missing bytes then completes it, and there
   is no `finish` step that promotes it to an error (§5.2).
   Cover a **`fixlen_word` cut after its first byte** too, with that byte carrying a
   **reserved subtype** (`0x4`–`0x7`): the subtype is already settled by the low 3 bits,
   so an implementation that evaluates it early answers `INVALID` where §4.1 requires
   `INCOMPLETE`. Nothing else in this list exercises the no-partial-evaluation rule —
   the dangling `0x80` above carries no settled sub-field to peek at.
7. **Skip tests** — decode while ignoring some fields and whole sub-sequences; assert
   correct resync on the following field.

### 7.3 Coverage

Match the bar set by existing ports. Wire a coverage job into CI and surface a badge in
the README. The expected coverage is >90%.

---

## 8. Assets Requirement

Copy the following files into the new repository's `assets/` folder:

* **`sofabuffers_logo.png`**, **`sofabuffers_icon.png`** — branding assets; copy from
  the `documentation` repository (`assets/`). Referenced by the README header
  (`<img src="assets/sofabuffers_logo.png" ...>`).
* **`test_vectors.json`** — the shared conformance suite (see §7), **generated by and
  copied from `corelib-c-cpp`** (the authoritative source). Its schema is documented
  alongside it in `corelib-c-cpp/assets/test_vectors_README.md`:
  * <https://raw.githubusercontent.com/sofa-buffers/corelib-c-cpp/refs/heads/main/assets/test_vectors.json>
  * <https://raw.githubusercontent.com/sofa-buffers/corelib-c-cpp/refs/heads/main/assets/test_vectors_README.md>

---

## 9. README Format

Every `corelib-*` README follows the **same shape** so the whole family of
libraries reads consistently — a reader who knows one port's README can navigate
any other. Reproduce the structure below, swapping in the target language's
specifics. **Do not change the section ordering and do not invent new top-level
sections**; that shared shape is the point.

Before editing a README, **read the corelib's actual source code.** Every fact,
command, version number, dependency, feature flag, and API name the README states
must match the code as it stands today — fix anything stale, inaccurate, or
misleading.

The sections, in order:

### 9.1 Generic header block (centered)

* Centered logo: `<p align="center"><img src="assets/sofabuffers_logo.png" alt="SofaBuffers" height="140"></p>`
* `# SofaBuffers`
* Tagline: `<b>Structured Objects For Anyone</b><br>` + `<i>... so optimized, feels amazing.</i>`
* A link back to the GitHub organization.

### 9.2 `## SofaBuffers <Language> library`

The opening section of every README, containing — in this order:

* **Badges** — CI, coverage, and a **Docs** badge. The Docs badge links to the API
  reference published on GitHub Pages (§12.2) and is the *only* pointer to API
  documentation the README carries.
* **GitHub link** — a link to this port's repository / the GitHub organization.
* **Short summary** — one paragraph on what makes *this* library special and why a
  reader should choose it: the language's selling points, the streaming guarantee,
  the small footprint, cross-language compatibility, etc.
* **Requirements** — the minimum required version of the runtime / language
  toolchain, plus the install command (`cargo add`, `pip install`, `go get`, …).
* **Dependencies** — every non-optional dependency and its minimum version (or an
  explicit "no runtime dependencies" when that is true). Keep these current as the
  library evolves.

### 9.3 `## Why this design`

A two-column table mapping design goals (streaming output, streaming input, zero
unnecessary copies, low/no allocation on the hot path, small footprint, type
safety, cross-language compatibility) to how *this* implementation achieves them.
Keep the table format — it must stay parallel across ports.

### 9.4 No API-documentation section

**There is no API-documentation chapter.** The **Docs** badge (§9.2) is the single
entry point to the generated API reference. Do **not** add a `## Source
documentation`, `## API reference`, `## API documentation`, or similar section, and
do not dump generated doc content into the README.

### 9.5 `## Usage`

Concise, runnable examples — in the language's idiomatic pattern — for each of:

* **Simple encode** — build a small message and produce its bytes.
* **Simple decode** — parse bytes back into values.
* **Streaming a message larger than the buffer** — drive the flush callback / sink
  with an output buffer smaller than the whole message.
* **OStream** — the output-stream / writer-sink wrapper.
* **IStream** — the input-stream / push-feed wrapper.
* **Generator** — using generated object code (the one-shot `encode()` / `decode()`
  helpers *and* the streaming `serialize` / `decoder()` path, §6.1.1). This is the
  most common real-world use case, so show it explicitly.

### 9.6 `## Memory handling`

Describe **only** the ownership and lifetime of the message buffers used for
encoding and decoding — who allocates each, who owns it, and how long it must
stay alive (borrowed vs. copied, caller-owned vs. library-owned). Do **not** turn
this into an API listing.

* **Output buffer (encoding)** — who owns the buffer written into, whether the
  library allocates or grows it, and what happens when it fills (flush sink /
  reuse vs. a buffer-full error). State the port's **`MIN_OUTPUT_BUFFER`** (§5.1)
  here, and that it applies to a buffer installed with a sink: it is the number a
  caller needs before it can size a streaming buffer, and this is the section they
  read to find out who allocates what. If the port implements **pass-through** of a
  `string`/`blob` run (§5.1), say so here too — it is the one case where a sink is
  handed memory that is not the output buffer, and a reader of this section needs
  to know before writing a sink that retains what it receives.
* **Input buffer (decoding)** — who owns the bytes being parsed and how long they must
  outlive the call. For the **one-shot** `decode(buffer)` this is where a port states
  whether decoded `string`/`blob` values are zero-copy views into the caller's buffer
  (valid as long as it is) or copies. For the **streaming** `feed(chunk)` there is nothing
  to choose: §6 requires a fed chunk to be reusable the moment `feed` returns, so a
  streaming decode always copies out. Say which of the two the port's `decode` does; do
  not restate the streaming rule.

State plainly whether the hot path allocates and whether any library-owned heap
memory exists (e.g. a small internal carry/accumulator for chunk-straddling
fields). Where it helps, add a short owner/lifetime table for the two buffers.
Keep the wording parallel across ports.

### 9.7 `## Build & test`

A short description of how to build the library and how to run the test suite
(including the shared vectors from `assets/`). Keep it brief — the commands and a
sentence each, nothing more.

### 9.8 `## Benchmarks`

Describe how to run the `perf` and `bench` tools (§10) and **what each measures**
(`perf` = CPU-independent per-op cost; `bench` = throughput in MB/s on the current
machine).

When a single language has **two** corelibs targeting **different use cases**
(e.g. a general build vs. a `no_std` / embedded build), add a final subsection that:

* explains the intended use case for each implementation, and
* includes a benchmark comparison table showing why both exist and when to prefer
  each.

Keep section ordering and wording close to the existing repos so the family of
libraries reads consistently.

---

## 10. Performance Testing

Every `corelib-*` repo ships **three** benchmark tools, in the language's idiomatic
benchmark folder (`benches/` in Rust, `cmd/perfbench/` in Go, a benchmark module in
Python/Java/C#, etc.):

* **`perf`** — CPU-speed-independent per-op cost (cycles/op via a hardware cycle counter
  where available, or instruction count under a profiler). Answers "how good is the
  implementation?" — machine-neutral.
* **`bench`** — practical throughput on the current machine, in MB/s. Answers "how fast
  is it here, right now?".
* **`run_callgrind.sh`** — instructions-per-op (Callgrind `Ir/op`): the deterministic,
  machine-independent per-op cost. Unlike `perf`'s cycles/op it is available on *every*
  target (no "cycle counter unavailable" fallback).

The **exact workloads, datasets, timing rules, throughput formula, and output grammar
are specified in [`BENCH_SPEC.md`](BENCH_SPEC.md) — the single source of truth** for the
cross-language benchmark suite. All three tools must follow it so the numbers are directly
comparable across languages; do not redefine workloads, timing, or output format here.

---

## 11. Dev Container

Every `corelib-<lang>` repository must include a `.devcontainer/` folder that provides a
ready-to-use, reproducible development environment based on Docker and VS Code Dev Containers.

### 11.1 Required Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the container image: Ubuntu 24.04 base, language toolchain, GitHub CLI (`gh`), Node.js LTS, and Claude Code (`@anthropic-ai/claude-code`). |
| `start.sh` | Starts the container interactively, mounts the workspace and a named `claude-config` volume, and loads `.devcontainer/.env` via `--env-file` if the file exists (prints a warning when absent). |
| `devcontainer.json` | VS Code Dev Containers configuration: references the `Dockerfile`, loads `.devcontainer/.env` via `runArgs`, and declares VS Code extensions — language-specific tools **plus** `anthropic.claude-code`. |
| `.env.example` | Committed template listing all supported environment variables (at minimum `GH_TOKEN` for the `gh` CLI). Each variable must have a comment explaining its purpose and required scopes. |

### 11.2 `.env` File (Secrets)

* `.devcontainer/.env` holds actual secret values and is **never committed**.
* `.devcontainer/.env` **must** appear in `.gitignore` — this entry is mandatory and must be present in every `corelib-*` repository.
* Developers copy `.env.example` → `.env` and fill in their values.
* `start.sh` passes `--env-file "$SCRIPT_DIR/.env"` to `docker run` when the file exists.
* `devcontainer.json` passes `"--env-file", "${localWorkspaceFolder}/.devcontainer/.env"` in `runArgs`
  so VS Code Dev Containers loads the same variables.

> **Note:** because `runArgs` always includes `--env-file`, the `.env` file **must exist** before
> opening the project as a Dev Container in VS Code. Copy `.env.example` → `.env` first — even
> with all values empty — to satisfy this requirement.

### 11.3 VS Code Extensions (`devcontainer.json`)

`devcontainer.json` must declare at minimum:

* **Language extensions:** debugger, formatter/linter, and any test-runner or build-tool integration
  idiomatic for the target language (see the existing `corelib-c-cpp` port for a concrete example).
* **`anthropic.claude-code`** — the Claude Code extension (required in every port).

---

## 12. GitHub Workflows

Every `corelib-<lang>` repository ships **two** GitHub Actions workflow files under
`.github/workflows/`.

### 12.1 CI — Build & Test (`ci.yml`)

Runs on every push to `main` **and** on every pull-request targeting `main`.

**Matrix build (optional)**

A matrix build is worthwhile when version differences can cause real divergence:

* **Scripting / interpreted languages** (Python, Node.js/TypeScript): different runtime
  versions frequently differ in standard-library behaviour, so testing against current
  stable and at least one prior release catches regressions early.
* **Compiler-versioned languages** (C/C++, Rust): testing with multiple compiler
  versions (e.g. GCC + Clang, or Rust stable + beta) surfaces portability issues.

For languages with a stable, single-vendor toolchain where version-to-version
differences rarely affect library code (e.g. Go, Java, C#), a single pinned version
is acceptable.

When a matrix *is* used, set `fail-fast: false` so a failure on one leg does not
cancel the remaining legs — all results must be visible. Use the official GitHub
Actions setup action for the language (`dtolnay/rust-toolchain`,
`actions/setup-python`, `actions/setup-go`, `actions/setup-java`,
`actions/setup-node`, etc.) and enable its built-in dependency cache. Example shape:

```yaml
strategy:
  fail-fast: false
  matrix:
    version: ["<current-stable>", "<previous-stable>"]
    os: [ubuntu-latest]          # add windows-latest / macos-latest for cross-platform targets
```

**Required steps**

1. `actions/checkout@v4`
2. Set up the runtime from `matrix.version` with caching enabled.
3. Install / restore dependencies.
4. Build in both debug and release configurations.
5. Run the full test suite, including the shared test vectors from `assets/`.
6. Generate a coverage report with the language's idiomatic tool
   (`cargo llvm-cov`, `coverage.py`/`pytest-cov`, `gcov`/`gcovr`, `go test -cover`,
   JaCoCo, Coverlet, etc.).
7. Upload the report to a coverage service (Codecov or equivalent) and wire the
   resulting badge into the README (see §9.2).

### 12.2 Docs — API Documentation (`docs.yml`)

Runs on push to `main` only (not on pull requests).

**Language → documentation tool**

| Language | Tool |
|----------|------|
| C / C++ | Doxygen |
| Rust | `cargo doc` |
| Python | Sphinx (`sphinx-apidoc` + HTML builder) |
| TypeScript | TypeDoc |
| Go | `pkgsite` / `godoc -http` static export |
| Java | Javadoc (`mvn javadoc:javadoc` or `gradle javadoc`) |
| C# | DocFX |

**GitHub Pages deployment — Actions-based (no `gh-pages` branch)**

The workflow must use GitHub's native deployment mechanism, not a `gh-pages` branch.
The repository's **Pages** setting (Settings → Pages → Build and deployment → Source)
must be set to **"GitHub Actions"**.

Required workflow-level permissions:

```yaml
permissions:
  pages: write
  id-token: write
```

**Required steps**

1. `actions/checkout@v4`
2. Set up the runtime, pinned to the current stable version (no matrix needed).
3. Install dependencies.
4. Generate the HTML documentation into a local output folder
   (e.g. `docs/html/`, `target/doc/`, `site/`).
5. Upload the folder as a Pages artifact:
   ```yaml
   - uses: actions/upload-pages-artifact@v3
     with:
       path: <html-output-folder>
   ```
6. Deploy to GitHub Pages:
   ```yaml
   - uses: actions/deploy-pages@v4
   ```

**Published URL**

The site is served at `https://sofa-buffers.github.io/<repo>/`. This URL is the
target of the **Docs badge** described in §9, item 2.

---

## 13. Conformance Checklist

A new `corelib-<lang>` is conformant when:

- [ ] All public symbols live under the `sofab` namespace (§6).
- [ ] API version constant/getter returns `1` (§6).
- [ ] Varint and zig-zag encode/decode match §4.1–4.2 exactly.
- [ ] Field header packing `(id << 3) | type` and all 8 wire types (§4.3) are correct.
- [ ] Fixlen word `(length << 3) | fixlen_type`, LE floats, UTF-8 strings without
      terminator, and blobs are handled (§4.6).
- [ ] Integer arrays, and fixlen arrays with a single shared fixlen word; no dynamic
      subtypes in fixlen arrays (§4.7–4.8).
- [ ] Sequence start/end framing, fresh ID scope, single-byte `0x07` end, skip-by-walking
      with depth tracking, and rejection of nesting beyond `MAX_DEPTH` = 255 (§4.9).
- [ ] The encoder can produce the canonical sequence encoding of MESSAGE_SPEC §2 in a
      **single forward pass** — an all-default `struct`/`union` field omitted, an
      all-default wrapper-array element still framed — either through a
      descriptor/object layer that decides per field before opening, or through the
      `begin_lazy` / `end` / `end_keep` framing API (§6). Held-back headers never make
      the bytes depend on the output-buffer size.
- [ ] **Streaming encode** into a smaller-than-message buffer via flush callback /
      sink, with mid-stream buffer swap (§5.1), over a **caller-supplied** buffer with a
      start offset — the corelib allocates no output buffer at all; the generated layer
      does, and hands one in like any other caller (§5.1).
- [ ] **`MIN_OUTPUT_BUFFER` declared** (§5.1), at most 20, stated in the README's memory
      section (§9.6), enforced on every buffer installed **with a sink** and on no other,
      and used as the size in the §7.2 item 4 encode test.
- [ ] **Streaming decode** via `feed` of arbitrarily small chunks, push-callback /
      pull-read, lazy field binding, and auto-skip (§5.2), returning the three-valued
      `COMPLETE` / `INCOMPLETE` / `INVALID` outcome with **no** `finish`/`finalize` step —
      `INCOMPLETE` surfaced, never auto-promoted to an error (§5.2).
- [ ] Result/error reporting follows the §6.3 baseline codes (or idiomatic exceptions
      where the language uses them by default; return codes / result objects otherwise).
- [ ] UTF-8 string-validity contract per §6.4 — byte-container targets expose
      `SOFAB_STRICT_UTF8` (ON by default; constrained profiles may default OFF /
      compile it out), Unicode-string targets are always strict (option omittable),
      symmetric (`INVALID` on decode, `InvalidArgument` on encode), OFF pinned to
      raw-or-reject (never silent `U+FFFD`/lossy), skipped fields never validated
      (skip stays a length jump), `utf8_valid` primitive exposed where codegen
      materializes byte-container strings, chunk boundaries never change the
      outcome, and conformance tests run with the check ON.
- [ ] The streaming primitives are sufficient to build a thin **generated-object**
      layer with a dead-simple API that *also* serializes/deserializes in chunks; the
      one-shot `encode()/decode()` helpers are thin wrappers over the streaming path,
      and the generated surface uses only the closed name set of §6.1.1 (§6.1).
- [ ] All shared **test vectors** pass for both encode and decode, plus chunked,
      roundtrip, malformed, and skip tests (§7).
- [ ] `assets/` populated per §8 — branding from `documentation`, `test_vectors.json`
      from `corelib-c-cpp`.
- [ ] README follows the family format with badges and the required sections (§9).
- [ ] `perf` (CPU-independent), `bench` (MB/s), and `run_callgrind.sh` (Callgrind
      `Ir/op`) tools present and runnable (§10).
- [ ] `.devcontainer/` folder present with `Dockerfile`, `start.sh`,
      `devcontainer.json`, and `.env.example`; `devcontainer.json` lists language-appropriate
      extensions and `anthropic.claude-code`; `.devcontainer/.env` is gitignored (§11).
- [ ] `ci.yml` builds and tests on push and PR; matrix across runtime versions used
      where version differences matter (scripting languages, multiple compilers);
      coverage report uploaded and badge wired into README (§12.1).
- [ ] `docs.yml` generates HTML docs and publishes to GitHub Pages via the
      Actions-based deployment (no `gh-pages` branch); Docs badge in README links to
      the published site (§12.2).

---

*This document is part of the SofaBuffers `documentation` repository and is the
language-independent specification of the format. The shared `test_vectors.json` is
authoritative for any detail not fully captured here.*
