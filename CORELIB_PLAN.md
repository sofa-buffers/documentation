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
as a non-canonical trailing-default array run is (MESSAGE_SPEC §3). The rule
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

### 4.9 Sequence Start (type `0b110`) and Sequence End (type `0b111`)

```
sequence start:  [ header_varint = (id << 3) | 0b110 ]
   ... child fields, possibly nested sequences ...
sequence end:    [ 0x07 ]      // (id = 0) << 3 | 0b111  ==  0x07, a single byte
```

* A sequence exists **only on the wire**: its sole effect is to open a **fresh ID
  scope**. It has no type meaning of its own — nothing more than a new scope.
* **Sequence end has no ID** (its ID is fixed at 0), so it is always the single byte
  `0x07`.
* Because the end is a marker (not a length), an encoder can stream a sequence of
  unknown size. A decoder that wants to skip a sequence must walk it to its matching
  end, descending into nested sequences and tracking depth.
* An **empty sequence** — a `sequence start` immediately followed by its `0x07` end —
  is legal and well-formed; a decoder must accept it. It is the composite-type
  counterpart of a zero-count array (§4.7); what an empty sequence *means*
  (explicit empty collection, all-default struct, …) is a message-layer concern
  (MESSAGE_SPEC §2, §4).
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
buffer. The output buffer can be **far smaller than the message**.

Required capabilities:

* Accept a fixed output buffer together with a flush callback, or connect to a
  language-idiomatic stream/writer sink — whichever pattern the language prefers.
* Support an optional start offset so the encoder can leave space at the front of
  the buffer for a framing header before its first byte.
* Allow a new output buffer to be installed mid-stream (typically inside the flush
  callback) so encoding continues without interruption or data loss.
* Expose an explicit flush to drain any remaining buffered bytes at the end.
* Return a status/error code on every write operation; if the buffer fills with no
  flush registered, report buffer-full rather than overflowing.

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
| **`INVALID`** | `ERROR` | the bytes are malformed **regardless of what follows**: a reserved fixlen subtype (`0x4`–`0x7`, §4.6), a fixlen `fp32`/`fp64` whose declared length is not exactly 4 / 8 (§4.6), a varint exceeding 64 bits (§4.1), a length or count above its maximum (§6.2), nesting past `MAX_DEPTH` (§4.9), a sequence-end marker with no open sequence, or an invalid-UTF-8 `string` payload when the strict UTF-8 check is enabled (§6.4) | no — terminal |

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
an overlong varint, a wrong-width `fp32`/`fp64` fixlen (§4.6), an over-maximum
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
* `sequence_begin(id)` and `sequence_end()` to open and close nested scopes.
* `flush()` and the ability to swap in a new output buffer mid-stream.

**Decoder**
* Initialize with a field handler (callback / visitor / pull-iterator).
* `feed(bytes)` accepting arbitrarily small chunks, returning the three-valued decode
  outcome `COMPLETE` / `INCOMPLETE` / `INVALID` (§5.2). **No** separate
  `finish`/`finalize`/`end` step — `INCOMPLETE` is surfaced to the caller, never
  auto-promoted to an error.
* Per-field: **read** the value into a typed destination, or **skip**. If the language
  supports overloading a single `read(destination)` suffices; otherwise use
  `read_<type>(destination)` variants.
* Descend into nested sequences with a child handler (e.g. `read_sequence`); auto-skip
  of unread fields and whole sub-sequences.

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
object should think in terms of *fields and (de)serialize*, never in terms of varints,
field IDs, sequence markers, or buffers. Target roughly this ergonomics (names adapted
per language):

```
person = Person()           # plain typed fields: person.name, person.age, person.tags[]
person.name = "Ada"
person.age  = 36

bytes = person.serialize()              # one-shot convenience
person2 = Person.deserialize(bytes)     # one-shot convenience
```

* Generated fields are ordinary typed members with language-natural accessors;
  IDs/types/order come from the schema and are hidden inside the generated code.
* Nested schema messages become nested generated objects; repeated fields become the
  language's natural list/array type.
* Provide one-line `serialize()` / `deserialize()` convenience methods for the
  90% case (message fits comfortably in memory).

**But generated objects must ALSO stream in chunks.** The convenience methods are
just shortcuts; every generated object must additionally accept an incremental path so
large objects never force a full in-memory buffer:

```
# streaming OUT: feed an existing ostream / sink; bytes leave as the buffer fills
person.serialize_to(ostream)            # writes via the corelib flush callback / sink

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
  swap** mechanism (§5.1), so `serialize_to` works with an output buffer smaller than
  the object.
* Let the generator drive decoding through the **push-feed + pull-read / visitor**
  mechanism (§5.2), so a generated decoder can consume **arbitrarily small `feed`
  chunks** and bind each decoded field straight into the object's member — including
  descending into nested generated objects via `read_sequence` and resuming a
  half-built object across chunk boundaries.
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
| `UsageError` | Invalid usage, e.g. a type mismatch on read. |
| `BufferFull` | Output buffer overflowed during encoding. |
| `InvalidArgument` | Invalid argument, e.g. a field ID out of range — or, with the strict UTF-8 check ON (§6.4), a `string` value that cannot be encoded as valid UTF-8 (non-UTF-8 bytes, an unpaired surrogate). |
| `InvalidMessage` | Malformed message while decoding — malformed **regardless of what follows**: an **overlong (`>64`-bit) varint**, an unbalanced sequence end, an oversized length/count, nesting past `MAX_DEPTH`, a reserved fixlen subtype, a wrong-width `fp32`/`fp64` fixlen (§4.6), or an invalid-UTF-8 `string` **when the UTF-8 check is enabled** (§6.4). Corresponds to the `INVALID` decode outcome (§5.2). **Truncation is _not_ `InvalidMessage`** — see the note below — but input that is *both* malformed and truncated *is*: `INVALID` takes precedence over `INCOMPLETE` (§5.2). |
| `LimitExceeded` | A configured **receiver-side technical limit** (§6.2.1) was exceeded on a schema-**unbounded** field — e.g. `max_dyn_array_count` / `max_dyn_string_len` / `max_dyn_blob_len`. The message is **well-formed**: the same bytes decode successfully under a looser or unset limit, so this says nothing about the message's validity and is **not** `InvalidMessage` and **not** the `INVALID` decode outcome (§5.2). It is a terminal, receiver-local **policy** rejection. Never raised for a field the schema bounds — there an over-bound value is `InvalidMessage` (MESSAGE_SPEC §7, §7.1). |

**Decode outcome vs. error code.** A decoder's per-`feed`/`decode` result is the
three-valued **decode outcome** `COMPLETE` / `INCOMPLETE` / `INVALID` (§5.2),
*not* one of the codes in this table. `INVALID` corresponds to
`InvalidMessage`; **`INCOMPLETE`** — bytes short of a complete field, i.e. truncation —
is **not** an error and **must not** be reported as `InvalidMessage`: it is surfaced to
the caller, who judges it per its own framing. There is **no** `finish`/`finalize` step
that turns an `INCOMPLETE` into `InvalidMessage`. The codes in this table cover the
*other* fallible operations (encoding, type-mismatched reads, argument checks).

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
  continuation byte) is malformed regardless of what follows → the decoder MAY
  report `INVALID` immediately, mid-payload (§5.2 precedence).

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

**Affected languages.** The hazard is acute — and unavoidable via the value
alone — wherever the language's **only** (or default) float value type is a
64-bit double, so any `fp32` handed to user/generated code is *already* widened:

* **JavaScript / TypeScript** — every `number` is a double; there is no `fp32`
  value type.
* **Python** — `float` is a double.
* **Dart** — the only floating type is `double`.
* **Lua** (default build), and any other language whose sole float value is a
  double, or that materializes `fp32` by first widening it.

Languages with a native non-widening 32-bit float type (`f32` / `float` in Rust,
C, C++, Go, Java, C#, Zig) are **not** structurally forced into the hazard — but
an implementation there **MUST STILL NOT** introduce it by routing an `fp32`
round-trip through a `double` (e.g. a generic "read as double" helper).

**Requirement (normative).** An implementation **MUST** reproduce the exact 4
wire bytes of every `fp32` payload — signaling NaN included — across
decode → re-encode, at **every** `fp32` position: a **scalar** `fp32` (§4.6)
**and** each element of an **`fp32` array** (§4.8). Concretely:

* The float **value** delivered to a value consumer **MAY** be a widened double
  — a value consumer only needs to know it is `NaN`. But a **bit-exact** consumer
  (transcode, round-trip, any re-encode) **MUST** be able to obtain the payload's
  **raw wire bytes** and re-emit them **verbatim** — it **MUST NOT** re-encode an
  `fp32` from the widened value.
* This holds on **every** decode surface the implementation exposes — push /
  visitor, streaming, and pull / cursor alike (a guard added to one surface but
  not another is the recurring defect class this section exists to prevent).
* `fp64` needs no such channel: a native double round-trips its own sNaN.

**How (guidance).** Deliver the `fp32` payload the same way a `string`/`blob`
payload is delivered — as the raw little-endian wire bytes (a zero-copy view or a
32-bit bits accessor) — *alongside* the convenience `value`, and re-encode by
writing those bytes directly (never `setFloat32` / reinterpret-from-double). Gate
the raw channel as opt-in if a per-element view would burden value-only array
decoding.

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
   * **Encode** into a buffer **smaller than the message**, driving the flush
     callback / sink repeatedly; assert the concatenated output is byte-identical to
     the one-shot output.
   * **Decode** by feeding the input **one byte at a time** (and in odd-sized chunks);
     assert the result is identical to feeding it all at once. This proves the state
     machine suspends/resumes at any byte boundary.
5. **Malformed-input tests** — an overlong (`>64`-bit) varint, an unbalanced sequence
   end, an oversized length/count, nesting past `MAX_DEPTH`, a reserved fixlen subtype
   (`0x4`–`0x7`) → must return the `INVALID` decode outcome (a well-defined error),
   never crash.
6. **Truncation tests** — a message cut short mid-field (a lone dangling varint such as
   `0x80`, a fixlen payload shorter than its declared length, an unclosed sequence) →
   must return **`INCOMPLETE`**, *not* `INVALID` and *not* `COMPLETE`. It is a
   well-defined non-error outcome; feeding the missing bytes then completes it, and there
   is no `finish` step that promotes it to an error (§5.2).
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
* **Generator** — using generated object code (the one-shot `serialize()` /
  `deserialize()` helpers *and* the streaming `serialize_to` / decoder path). This
  is the most common real-world use case, so show it explicitly.

### 9.6 `## Memory handling`

Describe **only** the ownership and lifetime of the message buffers used for
encoding and decoding — who allocates each, who owns it, and how long it must
stay alive (borrowed vs. copied, caller-owned vs. library-owned). Do **not** turn
this into an API listing.

* **Output buffer (encoding)** — who owns the buffer written into, whether the
  library allocates or grows it, and what happens when it fills (flush sink /
  reuse vs. a buffer-full error).
* **Input buffer (decoding)** — who owns the bytes being parsed, how long they
  must outlive the call, and whether decoded `string`/`blob` values borrow into
  that buffer (valid only during the callback, copy out to keep) or are copied.

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
- [ ] **Streaming encode** into a smaller-than-message buffer via flush callback /
      sink, with mid-stream buffer swap (§5.1).
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
      one-shot `serialize()/deserialize()` helpers are thin wrappers over the streaming
      path (§6.1).
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
