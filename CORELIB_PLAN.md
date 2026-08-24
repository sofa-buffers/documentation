<p align="center"><img src="assets/sofabuffers_logo.png" alt="SofaBuffers" height="140"></p>

# SofaBuffers — Corelib Implementation Plan

<b>Structured Objects For Anyone</b><br>
<i>... so optimized, feels amazing.</i>

This document specifies **what SofaBuffers is and how it works, independent of any
programming language**. A human *or an AI* can use it as the single source of truth to
produce a new **core library implementation (`corelib-<lang>`)** that is byte-for-byte
compatible with every existing one.

**How to read this document**

* **Normative** text uses the key words below. Everything else is context — background,
  rationale, or an example. Only the key words create an obligation.

  | key word | meaning |
  |---|---|
  | **MUST**, **REQUIRED** | An absolute requirement. An implementation that does not do this is **not conformant**, whatever else it gets right. |
  | **MUST NOT** | An absolute prohibition. Same weight as MUST. |
  | **SHOULD** | There may exist valid reasons in particular circumstances to do otherwise, but the full implications must be understood and weighed first. A port that deviates **records the deviation in its README** — one line, stated as fact; §9.0.1 still applies. |
  | **SHOULD NOT** | The same, in the negative: the behaviour is discouraged, and deviating needs a stated reason. |
  | **MAY**, **OPTIONAL** | Genuinely optional. A port that implements it and a port that does not are **both conformant**, and neither may assume the other's choice. |

  Sense as in RFC 2119 / BCP 14, but this table is the operative definition here — where
  the two differ, this table wins. **The key words are normative only in uppercase.**
  Lowercase *must* / *should* / *may* is ordinary prose and never creates an obligation on
  its own; where it restates one, the uppercase rule in the section it points to governs.

  Two conventions this document adds:

  * a heading marked **(normative)** means every rule under it binds, whether or not each
    sentence repeats a key word;
  * where a rule applies only to some targets, the exemption is stated **with** the rule —
    never assumed. If no exemption is stated, there is none.
* Each rule is stated **once**, in one section, and referenced by `§` elsewhere. If two
  places seem to state the same rule, the one whose heading names the topic is the
  normative one.
* Layer boundaries, because most mistakes are made here:
  * **this document** — the corelib: wire bytes, streaming, the API contract.
  * [`MESSAGE_SPEC.md`](./MESSAGE_SPEC.md) — the message layer: how schema types lower
    onto the wire, canonical encoding, schema bounds.
  * **SofaBuffers ARCHITECTURE** (in `generator`) — the generated layer: what generated
    code does, receiver-cap values, allocation shape.
  * [`BENCH_SPEC.md`](BENCH_SPEC.md) — benchmark workloads, timing, output format.
* **When this document and the shared test vectors disagree, the test vectors win.**

**Contents**

| § | Topic |
|---|---|
| 1 | The idea behind the protocol |
| 2 | Reference repositories and the shared test-vector source of truth |
| 3 | Core concepts — fields, IDs, scopes, sequences |
| 4 | The complete binary wire format (byte level) |
| 5 | The streaming model, and language-idiomatic patterns |
| 6 | The language-independent API contract, including the generated-object layer |
| 7 | Mandatory unit testing |
| 8 | The `assets/` requirement |
| 9 | The README format |
| 10 | Performance testing (`perf` + `bench`) |
| 11 | Dev container |
| 12 | GitHub Actions workflows |
| 13 | Conformance checklist |

---

## 1. The Idea

SofaBuffers is a **compact, self-describing, TLV-like binary format** for structured
messages — comparable in purpose to Protocol Buffers, but built around one hard
constraint:

> **Everything must be streamable.**
> Both serialization and deserialization work **in arbitrarily small chunks**, without
> ever holding the whole message in memory.

That constraint drives every other decision:

* **No length prefix on the message.** A message is a flat stream of fields. Sequences
  are delimited by explicit *start* and *end* markers, never by a byte count — so an
  encoder can emit a nested structure **without knowing its final size**.
* **Field-at-a-time processing.** Each field carries its own type and, where needed, its
  length. A decoder can act on a field the instant its header arrives, even before the
  payload does.
* **The message never decides an allocation.** Memory a decode commits is sized by the
  caller or by a constant this document fixes — never by a number that arrived on the
  wire (§6.6). This is what lets a firmware target and a server target run the same code.
* **Minimal overhead, one copy.** The codec writes into the buffer the caller installed
  and copies each decoded value into the destination the caller supplied — never a borrowed
  slice, never a view (§6.7). One memory model, on every path and in every language.
* **A heap-free codec, everywhere — not only where the target demands it.** The codec
  allocates nothing at all (§6.6): it runs on caller-owned, fixed-size storage on a server
  exactly as on a microcontroller. Dynamic memory lives in the generated layer and in the
  static helpers beside the codec, never inside it.
* **Small-value bias.** Integers are varint-encoded, so common small values cost one
  byte. The 3-bit type tag is packed *into* the field-ID varint, so a typical small
  field header is a single byte.

The type-encoding costs were chosen to match average field-type usage across other
message formats (JSON, Protocol Buffers), keeping overhead lowest for the most frequent
types.

---

## 2. Reference Repositories (Source Inputs)

| Repository | Language | Role |
|------------|----------|------|
| [`documentation`](https://github.com/sofa-buffers/documentation) | — | Format spec (this file, `MESSAGE_SPEC.md`, `BENCH_SPEC.md`), branding assets |
| [`corelib-c-cpp`](https://github.com/sofa-buffers/corelib-c-cpp) | C99 / C++20 | C/C++ embedded — **and the source of truth for the shared test vectors** |
| [`corelib-cpp`](https://github.com/sofa-buffers/corelib-cpp) | C++20 | C/C++ high speed |
| [`corelib-rs-no-std`](https://github.com/sofa-buffers/corelib-rs-no-std) | Rust `no_std` | Rust embedded |
| [`corelib-rs`](https://github.com/sofa-buffers/corelib-rs) | Rust | Rust high speed |
| [`corelib-py`](https://github.com/sofa-buffers/corelib-py) | Python | Python high speed |
| [`corelib-ts`](https://github.com/sofa-buffers/corelib-ts) | TypeScript | TypeScript high speed |
| [`corelib-go`](https://github.com/sofa-buffers/corelib-go) | Go | Go high speed |
| [`corelib-java`](https://github.com/sofa-buffers/corelib-java) | Java | Java high speed |
| [`corelib-cs`](https://github.com/sofa-buffers/corelib-cs) | C# | C# high speed |
| [`generator`](https://github.com/sofa-buffers/generator) | — | Schema → code generator; owns the ARCHITECTURE document |

**Shared artifacts** (copied into every new repo — see §8 for where they go):

| Artifact | From | Purpose |
|---|---|---|
| `sofabuffers_logo.png`, `sofabuffers_icon.png` | `documentation/assets/` | Branding, used by the README header |
| `test_vectors.json` | `corelib-c-cpp/assets/` | The language-agnostic conformance suite |
| `test_vectors_README.md` | `corelib-c-cpp/assets/` | The **authoritative** description of that file's format |

`corelib-c-cpp` **generates** the vectors. Never hand-write a divergent copy.
Raw links:
<https://raw.githubusercontent.com/sofa-buffers/corelib-c-cpp/refs/heads/main/assets/test_vectors.json>
·
<https://raw.githubusercontent.com/sofa-buffers/corelib-c-cpp/refs/heads/main/assets/test_vectors_README.md>

---

## 3. Core Concepts

A **message** is an ordered stream of **fields**. There is no envelope and no overall
length header.

| Term | Definition |
|---|---|
| **Field** | One `(ID, type, payload)` unit. |
| **ID** | An integer chosen by the schema author, identifying the field within its current scope. Range `0 .. 2,147,483,647` (§6.2). Unique within one scope; may repeat in different scopes. |
| **Type** | One of 8 wire types, a 3-bit tag (§4.3). |
| **Sequence** | A wire construct that opens a fresh ID scope — **and nothing else**. Opened by a *sequence start* field, closed by a *sequence end* marker (§4.9). |
| **Scope** | The ID namespace a sequence opens. Child IDs never collide with parent IDs. |

Two consequences that the rest of this document relies on:

* **A sequence carries no type semantics.** The message layer builds nested structures,
  dynamic arrays, arrays of variable-length elements, and tagged unions on top of this
  one primitive. How each schema type lowers onto sequences is defined in
  [`MESSAGE_SPEC.md`](./MESSAGE_SPEC.md) §4–§5, **not here** — to a corelib they are all
  just sequences.
* **Any field is skippable from its header alone.** A decoder that does not want a field,
  or an entire sub-sequence, can consume it using only header information.

---

## 4. Binary Wire Format

**Everything is little-endian.** Varints are LEB128-style (least-significant group
first, inherently little-endian); IEEE-754 floats are stored little-endian. There are no
big-endian fields anywhere.

### 4.1 Varint Encoding

Every integer in the format — field IDs, lengths, counts, and integer values, whatever
their declared bit width — is an **unsigned LEB128-style varint**:

* the value is split into 7-bit groups, least-significant first;
* each byte holds 7 payload bits in its low bits;
* bit `0x80` is the **continuation flag**: set = more bytes follow, clear = last byte.

```
value 0        -> 0x00        value 128      -> 0x80 0x01
value 1        -> 0x01        value 300      -> 0xAC 0x02
value 127      -> 0x7F        value 16384    -> 0x80 0x80 0x01
```

A decoder accumulates into at least a 64-bit register, shifting by 7 per byte.

#### 4.1.1 No value before the final byte (normative)

A varint has **no value** until the byte with a clear continuation flag arrives.

* A decoder **MUST NOT** evaluate any part of an incomplete varint — not a packed
  sub-field, not a partial magnitude.
* It **MUST NOT** let such a part influence an outcome, **even when those bits are
  already arithmetically fixed**.
* Until the varint ends, the construct it belongs to is `INCOMPLETE` (§5.2).

The bits are genuinely readable, which is why the rule has to be stated: each further
byte contributes a multiple of 128, and 128 is divisible by 8, so **the low 3 bits of any
varint are settled by its first byte**. Both packed words in this format live there:

| word | settled early | but yields its value only when |
|---|---|---|
| field header (§4.3) | wire type | the header varint ends |
| `fixlen_word` (§4.6) | fixlen subtype | that varint ends |

So a message ending inside a `fixlen_word` is `INCOMPLETE` even when the settled bits
already carry a **reserved subtype** `0x4`–`0x7`, and even when the field's id would
violate a schema bound (MESSAGE_SPEC §7.1) once the subtype confirmed the field is the
declared one (MESSAGE_SPEC §7.3). Those tests are satisfiable only on the complete word.

*Why:* the outcome must not depend on how far a decoder's varint loop happens to unroll.
Peeking splits one word into two decision points, so a push surface reporting the
completed word and a pull surface reading its first byte would reach different verdicts
for the same bytes — the chunk-boundary sensitivity §7.2 item 4 exists to catch. This does
not weaken §5.2's `INVALID`-over-`INCOMPLETE` precedence: that ranks constructs the decoder
has actually read, and an unfinished varint is not one.

#### 4.1.2 Minimality on encode, tolerance on decode (normative)

* An encoder **MUST** emit every varint in its **minimal form** — the fewest bytes that
  represent the value. (`5` is `0x05`, never `0x85 0x00`.) This is the byte-level face of
  the single-canonical-encoding rule, MESSAGE_SPEC §2.
* A decoder **MUST accept** a non-minimal varint within the 64-bit bound below, decode it
  to the value it denotes, and — since every re-encode is canonical — emit the minimal
  form on re-encode.
* A non-minimal encoding is therefore **not** `INVALID` (§5.2); it is normalized away.
* This applies wherever a varint appears: field headers, `fixlen_word`s, element counts,
  element values, and inside skipped fields.

#### 4.1.3 The 64-bit bound (normative)

A varint encoding **exceeds the 64-bit value range** — `INVALID` (§5.2) — iff:

* it is longer than **10 bytes**, **or**
* any payload bit would land at bit position ≥ 64 (a tenth byte with payload above `0x01`).

Both tests are on the **encoding**, not the decoded value: an 11-byte encoding is
`INVALID` even when its surplus bytes are zero, and a decoder **MUST NOT** silently
discard overflowing high bits.

### 4.2 Zig-Zag Encoding (signed integers only)

Signed integers map to unsigned via zig-zag, then varint-encode, so small negatives stay
small:

```
encode(n) = (n << 1) ^ (n >> (bitwidth-1))      // arithmetic shift
decode(u) = (u >> 1) ^ -(u & 1)

 0 -> 0      -1 -> 1      1 -> 2      -2 -> 3      2 -> 4 ...
```

Use **64-bit width** for the transform; values are `int64`-domain.

### 4.3 Field Header: ID + Type

Each field begins with one varint packing the ID and a 3-bit type tag:

```
header_varint = (id << 3) | type
```

The tag values are **normative**:

| Bits | Value | Wire type | Section |
|---|---|---|---|
| `0b000` | 0x0 | unsigned integer (varint) | §4.4 |
| `0b001` | 0x1 | signed integer (zig-zag varint) | §4.5 |
| `0b010` | 0x2 | fixlen value | §4.6 |
| `0b011` | 0x3 | array of unsigned integers | §4.7 |
| `0b100` | 0x4 | array of signed integers | §4.7 |
| `0b101` | 0x5 | array of fixlen values | §4.8 |
| `0b110` | 0x6 | sequence start | §4.9 |
| `0b111` | 0x7 | sequence end | §4.9 |

### 4.4 Unsigned Integer (type `0b000`)

```
[ header_varint ] [ value_varint ]
```

Examples: id `0`, value `0` → `00 00`. Id `0`, value `127` → `00 7f`.

**Booleans have no wire type of their own (normative).** A boolean is an unsigned integer
with value `0` or `1`.

* The corelib **MUST** provide dedicated boolean read/write functions performing that
  mapping.
* On the wire the result is indistinguishable from an unsigned integer. `boolean true` at
  id `0` → `00 01`.
* The shared vectors carry a `boolean` op accordingly.

Other schema types that lower to an unsigned integer (bitfields, flag sets) are a
message-layer concern (MESSAGE_SPEC §1); the corelib only ever sees a plain unsigned
integer.

### 4.5 Signed Integer (type `0b001`)

```
[ header_varint ] [ zigzag(value)_varint ]
```

Decode the varint, then zig-zag-decode. Schema types that lower to a signed integer
(enums, including their 32-bit range) are a message-layer concern (MESSAGE_SPEC §1).

### 4.6 Fixlen Value (type `0b010`)

```
[ header_varint ] [ fixlen_word_varint ] [ payload bytes... ]

fixlen_word = (length << 3) | fixlen_type
```

Length range `0 .. 2,147,483,647` (`FIXLEN_MAX`, §6.2). Subtypes:

| Bits | Value | Subtype | Payload |
|---|---|---|---|
| `0b000` | 0x0 | IEEE-754 32-bit float | exactly 4 bytes, little-endian |
| `0b001` | 0x1 | IEEE-754 64-bit double | exactly 8 bytes, little-endian |
| `0b010` | 0x2 | UTF-8 string | raw UTF-8, **no** trailing NUL |
| `0b011` | 0x3 | BLOB | opaque bytes |
| `0b100`–`0b111` | 0x4–0x7 | **reserved** | — |

Normative rules:

* **Wrong float width is `INVALID`.** A `fixlen_word` declaring any length other than 4 /
  8 for `fp32` / `fp64` is malformed (§5.2), and a decoder **MUST** reject it **when the
  `fixlen_word` is read** — before consuming or waiting for payload bytes (§5.2).
* **Reserved subtypes are `INVALID`.** A decoder **MUST** reject `0x4`–`0x7` (§5.2).
* **Floats round-trip bit-for-bit.** Payloads are raw IEEE-754 little-endian bytes, so
  `±0`, `±inf` and every `NaN` survive exactly. The corelib never inspects or normalizes
  a float payload. An `fp32` **signaling** NaN **MUST NOT** be quieted — see §6.5, which
  is normative for languages whose only float type is a double.
* **Strings carry no terminator.** Callers needing one append it themselves.
* **Skipping** consumes exactly `length` payload bytes.

*Testing note:* JSON cannot represent `NaN`, so the shared vectors omit it; conformance
tests compare floats by **bit pattern**, never `==` — since `NaN != NaN`.

### 4.7 Array of Unsigned / Signed Integers (types `0b011` / `0b100`)

```
[ header_varint ] [ element_count_varint ] [ elem_0_varint ] [ elem_1_varint ] ...
```

* `element_count` range `0 .. 2,147,483,647` (`ARRAY_MAX`, §6.2). It lets a decoder
  validate the destination or skip the array element by element.
* **`element_count` may be `0`** — a valid, fully-specified empty array, exactly
  `[ header ][ count = 0 ]`, no elements following, and no `fixlen_word` (integer arrays
  have none; their element width is an API concern, not a wire one).
* Each element is an independent varint (unsigned) or zig-zag varint (signed); byte
  length per element varies.
* The declared element width on the API (8/16/32/64-bit) affects only how a decoded value
  is **stored**, never the wire bytes.

What an explicit empty array *means* versus an absent field is a message-layer question
(MESSAGE_SPEC §2), not a wire one.

### 4.8 Array of Fixlen Values (type `0b101`)

```
[ header_varint ] [ element_count_varint ] [ fixlen_word_varint ] [ payload... ]
```

* One **single** `fixlen_word` gives the subtype and the **per-element** byte length,
  applying to all elements.
* Payload is `element_count × element_length` contiguous bytes.
* Only **fixed-width** subtypes are allowed: `fp32`, `fp64`. **String and blob are NOT
  allowed** in a fixlen array — model an array of strings with a sequence (§4.9).
* Elements are little-endian.
* **`element_count == 0` keeps the `fixlen_word`**: the field is exactly
  `[ header ][ count = 0 ][ fixlen_word ]`. Without it an empty `fp32` array and an empty
  `fp64` array would both be `[ header ][ count = 0 ]` and a decoder inferring the subtype
  from the wire could not tell them apart.

#### 4.8.1 Decode order: both words, then subtype, then schema bound (normative)

The `element_count` precedes the `fixlen_word`, so a decoder learns *how many* elements
there are before *of what type* — and those two answers belong to different authorities:
the **format** bounds the count, the **schema** bounds the array. A decoder therefore:

1. reads `element_count`, enforcing the format ceiling `ARRAY_MAX` (§6.2) as it does so,
   and committing no memory on the strength of that count before it has been checked
   (§6.2.1);
2. reads the `fixlen_word`, obtaining subtype and per-element length;
3. if the subtype **contradicts** the declared element type, **skips** the field per
   MESSAGE_SPEC §7.3 — `element_count × element_length` bytes — leaving the declared field
   at its default. The schema `count` **MUST NOT** be applied: the field was never this
   array's value, so its element count is not this array's count;
4. otherwise applies the **schema** `count` bound (MESSAGE_SPEC §7.1): an `element_count`
   above the declared `count` is `INVALID`.

This order costs nothing: a fixlen array cannot be skipped at all without the
`fixlen_word`, because the payload length is `element_count × element_length`. A
conformant decoder has already read both words before it can act either way.

Two consequences, both **intended**:

* A message ending **between** the two words is `INCOMPLETE`, not `INVALID`, even when the
  `element_count` already exceeds the schema `count` — the decoder cannot yet know whether
  this is the field it must bound. (§5.2 gives `INVALID` only to bytes malformed
  *regardless of what follows*; these are not.)
* The **format** ceiling still fires on the count word whatever the subtype turns out to
  be.

### 4.9 Sequence Start (`0b110`) and Sequence End (`0b111`)

```
sequence start:  [ header_varint = (id << 3) | 0b110 ]
   ... child fields, possibly nested sequences ...
sequence end:    [ 0x07 ]      // (id = 0) << 3 | 0b111, a single byte
```

A sequence's sole effect is to open a fresh ID scope (§3).

**Sequence end carries no information in its id (normative).**

* An encoder **MUST** emit a sequence end as exactly `0x07`.
* A decoder **MUST discard** the id: the marker closes the innermost open sequence
  whatever the id says, and re-encodes as `0x07`.
* The id sub-field exists only to keep every header one `(id << 3) | type` varint.

**Discarded is not unvalidated.** The id is bounded by `ID_MAX` exactly as every other
header's is (§6.2): an id above the ceiling is `INVALID` (§5.2), on a sequence end as
anywhere else. That bound is on the id's **value**, not its spelling — §4.1.2 is
untouched, so a non-minimal encoding of an in-range id (`0x87 0x00`, or an id of 3) is
accepted, decoded and re-emitted as `0x07`. There is deliberately **no exception** for
wire type 7: one rule covers every header, so a decoder validates the id where it reads
it and never branches on wire type first.

Further rules:

* **Skipping a sequence** means walking to its matching end, descending into nested
  sequences and tracking depth — the end is a marker, not a length.
* **An empty sequence** (`start` immediately followed by `0x07`) is legal and a decoder
  **MUST** accept it. It is the composite counterpart of a zero-count array (§4.7). What
  it *means* is a message-layer question (MESSAGE_SPEC §2, §4); §6's framing API is what
  lets an encoder decide without buffering.
* **`MAX_DEPTH` is 255** (§6.2). An encoder **MUST NOT** open more than 255 nested
  sequences; a decoder **MUST** reject deeper nesting as `INVALID` rather than risk
  unbounded recursion.

*Implementation note:* decoding a sequence-wrapped array needs no dedicated states. After
a `sequence start` the decoder is back in its idle state reading ordinary field headers,
so array-of-composite reuses idle + sequence-push/pop + leaf states, and skipping nests
through the same depth counter. Only the count-prefixed array types (§4.7–4.8) need
count-driven states.

### 4.10 Worked Example

Message `{ id=0: unsigned 127 }`:

```
00        header: id=0, type=0b000 (unsigned)
7f        value varint = 127
```

→ `00 7f`, 2 bytes. This is exactly test vector `unsigned_0x7F`.

---

## 5. The Streaming Model (the heart of the design)

Every implementation **MUST** be streaming-capable on both sides: the message may be
larger than any buffer the program holds, and may be produced or consumed incrementally.

### 5.1 Streaming Serialization (Encoder)

The encoder writes into an **output buffer** and invokes a **flush/drain** operation when
it fills (or on explicit flush). The flush forwards the accumulated bytes downstream; the
encoder continues into the now-empty buffer.

**The output buffer MAY be arbitrarily smaller than the message (normative).** What
bounds memory is the buffer, not the message.

#### 5.1.1 Required capabilities

* Accept a **caller-supplied output buffer** — pointer/slice, length, start offset —
  **without** a flush sink. The offset leaves room at the front for a framing header; a
  buffer that fills reports buffer-full rather than overflowing.
* Accept the same buffer **with** a flush callback, or connected to a language-idiomatic
  stream/writer sink.
* Allow a **new output buffer to be installed mid-stream** (§5.1.5).
* Expose an **explicit flush** to drain remaining bytes at the end.
* Return a status/error code on every write operation.

#### 5.1.2 A corelib MUST NOT

* **Allocate an output buffer.** Every buffer the encoder writes into is caller-supplied.
  One buffer-ownership model, not two; a heap-less profile is the plain reading of it, not
  a special case. This is the encode half of **§6.6**.
* **Grow or reallocate** a caller-supplied buffer. What was handed over is what gets
  written.
* **Return partial output as if it were complete.** An encoder that could not write what
  it was asked to write reports it, and a one-shot helper that ignores that report is
  non-conformant.

The storage a one-shot `encode()` hands back comes from the **generated layer**, which
knows the schema (§6.6). Two shapes are conformant and the generator emits both:

| schema | shape |
|---|---|
| **bounded** | allocate `MAX_SIZE` (§6.1.1), install **without** a sink, encode in one pass. The worst case is derived from the schema and cannot be exceeded, so no flush occurs and no minimum applies. |
| **unbounded** | `MAX_SIZE` is a configured ceiling, not a size the message cannot reach, so sizing from it would truncate. Install a scratch buffer **with** a sink that appends into the growing result; the scratch is subject to `MIN_OUTPUT_BUFFER` like any sink-installed buffer. |

On a heap-less profile only the bounded shape exists — which is why MESSAGE_SPEC §7.2
already requires a schema intended for one to declare its bounds.

#### 5.1.3 Where a flush boundary may fall (normative)

The produced byte sequence is a concatenation of **atomic units** and **divisible runs**.

| class | members |
|---|---|
| **Atomic** | a field header varint (§4.3); a `fixlen_word` (§4.6); an `element_count` varint (§4.7–4.8); the varint of an integer scalar or of one integer array element (§4.4–4.5, §4.7); one `fp32`/`fp64` element (§4.6, §4.8) |
| **Divisible** | the payload byte run of a `string` or `blob` (§4.6), at any byte boundary |

* A flush boundary **MAY** fall between two atomic units and anywhere inside a divisible run.
* An encoder **MUST** be able to split a divisible run across a flush — a field without a
  schema `maxlen` can exceed any buffer, so no minimum removes that path.
* An encoder **MAY** require each atomic unit to land contiguously.

The rule is stated over the **produced bytes**, not the caller's data: a target whose
native string is UTF-16 emits a payload run its input never was, and it is the run in the
buffer that a flush divides.

#### 5.1.4 `MIN_OUTPUT_BUFFER` (normative)

A corelib **MUST** expose a documented constant — the smallest buffer it accepts **for
streaming**.

| port behaviour | declares |
|---|---|
| splits atomic units too | **`1`** |
| requires atomic units contiguous | the largest run it reserves as one piece; derived floor **10** (a 64-bit varint, `ceil(64/7)`) |
| reserves a header together with its value | that sum |

* A declaration **MUST NOT** exceed **20** — a header varint and its value, `2 × 10`.
  That is the largest reservation any port makes and also the smallest message a schema
  can bound, so a higher ceiling would let a port demand more than a whole message can
  occupy.
* Reserving further ahead — a field's metadata as a group, a batch of array elements —
  **MUST** be handled by flushing, not by raising the declaration.
* **The minimum binds a buffer installed with a flush sink**, at installation and at every
  mid-stream buffer-set. Such a buffer **MUST** satisfy `buflen - offset >=
  MIN_OUTPUT_BUFFER` and is rejected **where it is handed over**, by the same mechanism
  the port uses for an out-of-range offset — never partway through a message.
* Any buffer at or above it **MUST** work and **MUST** produce output byte-identical to
  the one-shot path.
* **A buffer installed without a sink is subject to no minimum.** No flush can occur, so
  no atomic unit can be split. The buffer either holds the message or reports
  buffer-full. This is the case a caller sizes from `MAX_SIZE` (§6.1.1), and it stays
  exact: a two-byte message encodes into a two-byte buffer on any port.

*Why a constant rather than a fixed floor of 1:* a caller writing portable code must be
able to **discover** the size that works instead of finding out at runtime. Confining the
constant to the streaming case keeps it from imposing a floor on the one-shot path, where
no flush can occur.

**Declaring `1` stays fully conformant** and is the right choice for a footprint profile:
byte-granular encoding is what the wire format was designed around, and on a target
streaming through tens of bytes of scratch it costs less than the RAM a larger buffer
would. Note the direction — here the **constrained** profile is the strict one and the
max-speed profile takes the allowance, the reverse of §6.2's constrained-profile
allowances. Unlike those, this changes nothing on the wire; only an API precondition
differs.

#### 5.1.5 Buffer handover: what a returning flush callback leaves behind (normative)

A sink may **copy** the bytes it was handed or **take** the buffer (pass it to a
transport, queue it, hand it to DMA), and the encoder cannot tell the two apart. The
contract therefore rests on what the callback does **before it returns**:

| the callback returns | means | the encoder |
|---|---|---|
| **without** installing a buffer | the sink **copied** | resumes writing into the active buffer at offset **0** |
| **after** installing a replacement | the sink **took** the buffer | writes into the replacement |

A sink that takes the buffer **MUST** install a replacement before returning. It **MUST
NOT** return without one — the encoder would keep writing into storage the transport now
owns.

**The start offset belongs to the installation, not to the buffer.** Each buffer-set call
begins a new installation whose cursor starts at *that call's* offset; the offset is then
consumed, so a later flush the callback returns from without installing resumes at 0.
Passing the **same** buffer to buffer-set is a new installation like any other — that is
how a sink gets fresh header room in **every** flushed unit, one framing header per
packet.

*Why this way round:* handing the **output buffer** to a transport is the reason buffer-set
exists — encode straight into the packet, hand the packet on, encode the next into another.
(This is an encode-side buffer handover and is unrelated to the decoded-value views §6.7
forbids: the buffer is the caller's, and the caller is the one giving it away.) That is only safe if
"returned without installing" has exactly one meaning. Reading it as "reuse the storage"
is the safe default for a copying sink and is what a taking sink must override; the other
way round would make the dangerous case the implicit one.

#### 5.1.6 Pass-through of a divisible run is forbidden (normative)

**An encoder MUST NOT hand any memory other than the installed output buffer to the sink.**
Every byte a sink receives lies inside the buffer the caller installed, at every flush,
without exception. A `string` or `blob` payload run is copied through the output buffer like
anything else, however large it is and wherever its bytes already live.

An earlier revision permitted an encoder to pass such a run to the sink directly, saving a
copy. That permission is withdrawn, for two reasons:

* **It contradicts what a chunk is.** A flushed unit is not merely "some bytes" — it may be
  a fragment of a lower-layer protocol, framed by the caller with room reserved at the front
  (§5.1.1) and handed to a transport as a unit. Foreign memory arriving in the middle of that
  sequence is not such a fragment: it carries no reserved header room, it cannot be framed,
  and it makes the sink's argument mean two different things on two consecutive calls.
* **It bought a copy at the price of a second contract.** Pass-through needed a permission
  flag at installation, an ordering rule about draining, a borrowing rule about retention,
  and a mutual exclusion with the buffer-set operation — four rules, each with a failure mode
  that only shows up under a sink that takes buffers. That is complexity the corelib carries
  forever, in every port, so that one payload shape avoids one copy.

**Consequences a port must not misread:**

* This says nothing about **where a flush boundary may fall** (§5.1.3). A divisible run may
  still be split across flushes at any byte — it is copied into the buffer first.
* It does not restrict the **caller**. A caller that wants to avoid the copy sizes its
  output buffer to hold the payload and installs it without a sink (§5.1.4).
* The **buffer-handover** contract (§5.1.5) is unaffected and is now the *only* way a sink
  ever influences which memory the encoder writes into.


See §6 for the full list of write operations.

### 5.2 Streaming Deserialization (Decoder)

The decoder uses a **push-feed / pull-read** model:

* **Push** — the caller feeds raw bytes in arbitrarily small chunks. A header or payload
  may be split across many `feed` calls; the state machine suspends and resumes at **any**
  byte boundary.
* **Event** — as soon as a complete field header `(id, type)` is parsed, the decoder
  notifies the **field handler** — the visitor, which is the only decode surface (§5.3.1).
* **Pull** — the handler chooses per field:
  * **read** the value into a typed destination;
  * **descend** into a nested sequence, recursively — with a child handler or by flat
    begin/end notification, whichever shape the port took (§6.0);
  * **skip** — the field's remaining bytes, or the whole sub-sequence, are consumed and
    discarded automatically as chunks arrive.

This split is what makes input-side streaming possible: the consumer never holds the whole
message and binds output storage lazily, per field.

*Terminology:* "pull-read" names what happens **inside the visitor callback** — the handler
pulls the value into its own destination. It is not a pull-parser *surface*, which §5.3.1
forbids: the codec still drives, and the handler is called; nothing outside the visitor
iterates the message.

#### 5.2.1 Decode outcome: three values, no finalize step (normative)

A chunk boundary may fall **anywhere**, including mid-field. Every `feed` — and the
one-shot `decode`, which is a single `feed` of the whole input — returns exactly one of
three outcomes, describing the bytes consumed **so far**:

| outcome | one-shot alias | meaning | can more bytes change it? |
|---|---|---|---|
| **`COMPLETE`** | `OK` | the consumed bytes end **exactly** at a field boundary; a valid message *may* end here | more valid fields may extend it |
| **`INCOMPLETE`** | `OK_BUT_INCOMPLETE` | the bytes end **inside** a field; the partial tail is retained for the next `feed` | **yes** |
| **`INVALID`** | `ERROR` | the bytes are malformed **regardless of what follows** (§5.2.2) | no — terminal |

**`INCOMPLETE` is NOT an error.** It is a first-class outcome, returned the same way from
a one-shot `decode` and a streaming `feed`. A conformant decoder **MUST** report it
distinctly and **MUST NOT** fold it into either neighbour:

* folding into `COMPLETE` (treating a truncated tail as finished) is non-conformant;
* folding into `INVALID` (rejecting a stream merely split across chunks, or a prefix the
  caller may still extend) is non-conformant.

#### 5.2.2 What makes bytes `INVALID` (normative, the single list)

This list is referenced from everywhere else in this document; it is not restated.

| condition | section |
|---|---|
| a varint longer than 10 bytes, or with payload bits at position ≥ 64 | §4.1.3 |
| an **id**, length or count above its format ceiling | §6.2 |
| a reserved fixlen subtype `0x4`–`0x7` | §4.6 |
| an `fp32`/`fp64` fixlen whose declared length is not exactly 4 / 8 | §4.6 |
| nesting past `MAX_DEPTH` | §4.9 |
| a sequence-end marker with no open sequence | §4.9 |
| an element count above the declared schema `count` | MESSAGE_SPEC §7.1 |
| an invalid-UTF-8 `string` payload **that is read**, with the strict check enabled | §6.4 |

Two things are deliberately **not** on this list: a **non-minimal varint** (§4.1.2,
normalized away) and a **receiver-cap rejection** (§6.2.1, a policy category of its own).

#### 5.2.3 Precedence: `INVALID` wins over `INCOMPLETE` (normative)

When the bytes consumed so far contain any §5.2.2 condition, the outcome is **`INVALID`**
even if the input is *also* truncated. `INCOMPLETE` is reported **only** when every
construct consumed so far is well-formed and the bytes simply end before the message does.

A decoder **MUST NOT** report `INCOMPLETE` for input it has already determined malformed —
no continuation can make it valid, so `INCOMPLETE` would wrongly invite the caller to feed
more. This does not conflict with the anti-folding rule of §5.2.1: a well-formed prefix
that is merely truncated stays `INCOMPLETE`.

**Consequently, a decoder MUST validate a construct where its describing bytes are read** —
the field header, `fixlen_word`, or count — before consuming, buffering, or waiting for the
payload they describe. A decoder that defers until the payload arrives can reach
end-of-input first and mis-report malformed input as `INCOMPLETE`.

> Example: `56 0a 59` — a nested `fp64` whose `fixlen_word` declares length 11 ≠ 8, then
> truncates. The `fixlen_word` alone proves the message malformed: `INVALID`, not
> `INCOMPLETE`.

**Two exceptions**, each stated where it belongs and neither weakening this rule:

* an **unfinished varint** carries no verdict at all (§4.1.1) — it is not a construct the
  decoder has read;
* **UTF-8 invalidity** is reported at payload completion rather than pulled forward
  (§6.4), because that check is not a property of the wire.

#### 5.2.4 No finalization — the caller owns end-of-input (normative)

The three outcomes are a property of the bytes consumed so far and computable at **any**
byte boundary from the decoder's own state. A decoder therefore needs **no**
`finish`/`finalize`/`end` step and **MUST NOT** provide one that reclassifies `INCOMPLETE`
as `INVALID`. The status `feed`/`decode` returns *is* the answer.

Whether `INCOMPLETE` is acceptable is the **caller's** decision — only the caller knows its
framing:

| caller | reads `INCOMPLETE` as |
|---|---|
| streaming | "feed me the next chunk" |
| outer frame (length prefix, datagram, EOF) that has delivered everything | the message was **truncated** — an error at *its* layer |
| one-shot requiring a whole message | failure; it accepts only `COMPLETE` |

**The framing invariant**, expressed purely through the returned status:

* a valid, whole message is consumed **exactly** → `COMPLETE`, nothing pending;
* truncation (bytes short of a complete field) → `INCOMPLETE`;
* trailing bytes that *begin* but do not finish another field → `INCOMPLETE`;
* trailing bytes that cannot begin any valid field → `INVALID`;
* a lone dangling `0x80` fed on its own → **`INCOMPLETE`**: a well-formed varint prefix
  (§4.1.1) that more bytes could complete. The decoder never decides on the caller's
  behalf that a prefix is truncated.

Generated code passes this status through verbatim (MESSAGE_SPEC §7).

### 5.3 Language-Idiomatic Patterns

A new implementation **SHOULD** use the best idiomatic pattern for its language, as long
as the wire bytes and the streaming guarantees are preserved.

#### 5.3.1 The visitor is the only decode surface (normative)

**A corelib exposes exactly one decode surface: the visitor.** The decoder calls typed
visitor methods on a caller-supplied object; pull-reading becomes "the visitor writes the
decoded value into one of the object's own members and skips what it does not recognise".

* Every port **MUST** expose it. In a language without objects it is **callbacks with a
  context pointer** — the same shape without the type — which is how C satisfies this, and
  is not an exemption.
* A port **MUST NOT** offer any second decode surface: no pull-parser, no iterator or
  `next()`-style API, no cursor, no convenience wrapper that decodes by another route. This
  holds for constrained targets too; there is no embedded exemption.

*Why one surface, and why this one:*

* The primary consumer is **generated code** — objects whose members mirror the schema
  fields and already exist at decode time. Writing straight into a member the caller owns
  needs no storage of its own, which is what makes the heap-free codec of §6.6 reachable at
  all. A surface that hands back values it materialized has to build them somewhere.
* **Every additional surface is a second implementation of every rule in this document.**
  §6.5 already names the recurring defect: a guard added to one surface but not another. The
  same divergence has appeared in chunk handling, in UTF-8 validation and in skip behaviour,
  and each time it was invisible to the shared vectors, which exercise whichever surface the
  driver happened to pick.
* A port with one surface has one place to be correct.

#### 5.3.2 Other patterns, where they still apply

These concern the **encoder** and the build, not the decode surface:

* **Flush callback / writer sink** — model the flush as a closure or a stream/writer sink,
  whichever the language prefers (§5.1).
* **Heap-free build** — required of the codec everywhere (§6.6); on targets that can go
  further, extend it to the whole library.
* **Feature flags / build options** — disable fixlen, fp64, array or sequence support and
  integer-overflow checks, or narrow the scalar value width to 32-bit, to shrink footprint.
  A narrowed width lowers `ID_MAX` and the value domain with it (§6.2). Every option here
  that a peer can observe is a §6.2.2 variation and carries that section's duty.
* **Native-acceleration readiness** for scripting languages — a pure-language implementation
  is a valid start, but isolate the hot-path primitives (varint encode/decode, buffer
  operations, header parsing) behind internal helpers, so they can be swapped for a native
  extension **without changing the public API**: same names, same argument shapes, same
  return types.


Keep the **public API surface and naming reasonably parallel** across languages
(encode/decode, sequence begin/end, read/skip) so users moving between languages stay
oriented.

---

## 6. Language-Independent API Contract

A conforming `corelib-<lang>` exposes at least the capabilities below. Adapt **names** to
the language's conventions; **semantics are fixed**.

**Namespace and package name (normative)**

| | value | note |
|---|---|---|
| namespace / module / crate / prefix | **`sofab`** | fixed, in **every** target. Not `SofaB`, not `Sofab`, not `sofabuffers`. |
| package name in the registry (crates.io, PyPI, npm, Maven Central, …) | **ecosystem-idiomatic, derived** | the organization slug `sofa-buffers` and the word `corelib`, written in the registry's own convention, plus a variant suffix where one language ships more than one corelib (§9.8). |

The namespace is the normative half: it is what user code reads, it is identical in every
target, and a port that gets it wrong is not conformant. The registry name is **not** fixed
by this document, because the registries do not admit one string — npm rejects uppercase in
new package names, Maven Central has no single package name (a coordinate is
`groupId:artifactId`), and a language shipping two corelibs cannot serve both from one name.
A port **MUST** publish under a name derived as above and **MUST** state that name in its
README (§9.2); it **MUST NOT** invent a brand of its own.

**API version.** Expose a constant or getter returning the integer API version, currently
**`1`** (§6.2). Callers and the generator use it to verify compatibility.

### 6.0 Operations

**Encoder**

* Initialize with an output sink — buffer + flush, or a stream/writer (§5.1).
* **Write** operations for every scalar type: unsigned, signed, boolean, fp32, fp64
  *(optional/feature-gated)*, string, blob. Boolean maps to an unsigned `0`/`1` (§4.4).
  With overloading, one `write(id, value)` dispatching on type; otherwise
  `write_<type>(id, value)`.
* **Array write** for unsigned-integer, signed-integer and fixlen (fp32/fp64) arrays.
* **Sequence framing** — opening and closing scopes in a form that lets the message layer
  omit an all-default sequence **without buffering the message** (§6.0.1).
* `flush()`, and the ability to swap in a new output buffer mid-stream (§5.1.5).

**Decoder**

* Initialize with a field handler: the **visitor** (§5.3.1), and no other surface.
* `feed(bytes)` accepting arbitrarily small chunks, returning `COMPLETE` / `INCOMPLETE` /
  `INVALID` (§5.2). **No** `finish`/`finalize` step.
* Per-field **read** into a typed destination, or **skip** — exactly these two intents,
  never a third (§6.7.2). With overloading a single `read(destination)` suffices; otherwise
  `read_<type>(destination)`.
* **Descend** into nested sequences, with auto-skip of unread fields and of whole
  sub-sequences. Two shapes are conformant and a port **MUST** implement one:
  * a **child handler** — the visitor returns a handler for the nested level
    (`read_sequence`, `BeginSequence`, `on_sequence_begin` → handler);
  * **flat begin/end** — the visitor is notified that a level opened and closed, and tracks
    its own depth.

  They are functionally identical — same bytes, same outcomes, same auto-skip — and differ
  only in which the language makes cheaper: handing back a borrowed handler per level is
  natural in Go, Dart and Python, and awkward under Rust's borrow rules. What is normative
  is the **capability**: a decoder **MUST** consume a nested sequence without the caller
  parsing it, and **MUST** skip an unwanted sub-sequence whole. Neither shape is a second
  decode surface (§5.3.1) — a child handler is part of the same visitor.

**Chunk lifetime (normative).** A fed chunk is borrowed **only for the duration of the
`feed` call**. Once `feed` returns, the caller may reuse, overwrite or free that memory and
the decoded message **MUST NOT** be affected. A decoder therefore copies out of a chunk
before returning — as it already must for a payload split across chunks, which has no
single chunk to point at.

**There is no exception for the one-shot path.** `decode(buffer)` copies exactly as `feed`
does, even though the caller demonstrably keeps that buffer alive — otherwise a port's
memory behaviour would depend on which entry point was used (§6.7.1).

*Why:* without this rule the caller's obligation would depend on where the chunk
boundaries happened to fall — a payload arriving whole in one chunk borrowed, the same
payload split across two copied — so the *same message over a different chunking* would
place different requirements on the same calling code. §6.4 and §7.2 item 4 already forbid
that class of variation for the decode outcome; memory obligations get the same answer.

#### 6.0.1 Sequence framing: `begin_lazy` / `end` / `end_keep` (normative outcome)

MESSAGE_SPEC §2 omits a sequence-typed **field** whose value equals its declared default,
and keeps the frame of a wrapper-array **element** that is all-default. Both are decided
by *what the children turn out to be*, while the sequence header has to be on the wire
**before** them. A naive encoder would buffer the sub-message to find out. It does not
have to.

**The obligation on a corelib is the outcome.** The shape below meets it in a single
forward pass:

| operation | effect |
|---|---|
| `sequence_begin_lazy(id)` | opens a scope and **holds the header back**. The ids of the innermost open sequences form a pending run. |
| any field write | first emits the whole pending run, outermost header first, then the field. Writing content is what proves every enclosing sequence non-default. |
| `sequence_end()` | if this sequence's header is still held back it received no content: **drop it**, header and end marker both. Otherwise emit `0x07`. |
| `sequence_end_keep()` | behaves like a write: emit the pending run *and* the end marker, so a sequence that got no content still reaches the wire as `begin` + `end`. |

The choice between the two closers is **static** — a property of the position in the
schema, so generated code decides it at generation time:

| position | closer |
|---|---|
| `struct` / `union` field | `end` |
| array field (the wrapper) | `end` |
| wrapper-array **element** (`struct`/`union`/nested row) | `end_keep` |
| array field already known to differ from a **non-empty** declared `default` | `end_keep` |

**`end_keep` is the safe default** because the failure directions are not symmetric: using
it where `end` would do costs one non-canonical empty frame that a decoder normalizes away
(MESSAGE_SPEC §2), while the reverse drops an element and silently changes an array's
**length**.

**Holding a header back never changes the bytes.** Pending ids are encoder state, not
buffer content, so a flush cannot split a pending run and a smaller-than-message output
buffer produces exactly the one-shot bytes (§5.1, §7.2).

**This is a recommended shape, not a mandated API.** What every implementation **MUST**
produce is the canonical encoding of MESSAGE_SPEC §2.

* An implementation whose message layer is a **descriptor/object table** can test each
  field against its default *before* opening anything (as the C reference does in
  `sofab_object_encode`) and meets the obligation with the plain eager
  `sequence_begin` / `sequence_end` pair.
* The hold-back trio exists for the other case: when the message layer is **generated
  code**, the predicate is spread across dozens of individual write calls and the output
  stream is the only place that sees them all.
* A profile that exposes the trio only for generated-code consumers **MAY** make it a
  build option (the C reference gates it behind `SOFAB_DISABLE_LAZY_SEQ_SUPPORT`). Such a
  switch changes the context layout and **MUST** be configured identically for the library
  and everything that includes it. It is a §6.2.2 variation and is stated like any other.

**How deep the hold-back reaches (normative).** The pending run grows with nesting.

* The pending run is **fixed-size state** (§6.6.2): at most `MAX_DEPTH` ids, sized at
  construction. An implementation **MUST** hold back to the full `MAX_DEPTH` (§6.2) and is
  thereby canonical at every depth.
* A **constrained profile MAY** bound the run to a smaller fixed depth and frame eagerly beyond it,
  emitting the empty frame §2 would have omitted. That output is **well-formed and decodes
  to the same value** — it is the non-canonical form every decoder already accepts and
  normalizes — so the two profiles interoperate. What it is not is canonical.
* A profile taking this allowance **MUST state the bound** it chose (§6.2.2).

This is the same constrained-profile allowance as §6.2's, for the same reason: a bound that
costs RAM per stream is a real cost on a target that has none to spare.

### 6.1 Two Audiences: Direct corelib Use vs. Generated Objects

A corelib has **two** kinds of users and the API must serve both:

1. **Direct use (power user).** A developer calls the raw encoder/decoder by hand,
   choosing field IDs and read/write calls. Fully supported, and the right choice for tiny
   embedded messages or one-off wire work.
2. **Generated objects (the normal path).** The **`generator`** turns a schema into
   ready-made objects/classes/structs in the target language, and the developer never
   touches the raw API.

> **Architectural hint:** design the corelib so a *thin* generated layer can sit on top.
> The generated objects are the product most humans interact with, so **their API must be
> extremely simple** — while the corelib underneath still exposes enough hooks that those
> objects can be serialized and deserialized **in chunks**.

**Generated objects must be dead simple.** A human using a generated `Person` thinks in
fields, encode and decode — never in varints, field IDs, sequence markers or buffers:

```
person = Person()           # plain typed fields: person.name, person.age, person.tags[]
person.name = "Ada"
person.age  = 36

bytes   = person.encode()               # one-shot convenience
person2 = Person.decode(bytes)          # one-shot convenience
```

* Generated fields are ordinary typed members; IDs, types and order come from the schema
  and stay hidden.
* Nested schema messages become nested generated objects; repeated fields become the
  language's natural list/array type.
* One-line `encode()` / `decode()` cover the 90% case.

**But generated objects must ALSO stream.** The convenience methods are shortcuts; every
generated object additionally accepts an incremental path:

```
# streaming OUT: feed an existing ostream / sink; bytes leave as the buffer fills
person.serialize(ostream)

# streaming IN: drive a decoder fed with arbitrarily small chunks
dec = Person.decoder()
st = dec.feed(chunk1); st = dec.feed(chunk2); ...   # COMPLETE / INCOMPLETE / INVALID
person = dec.value                                   # assembled incrementally
# No finish()/end(): `st` is the outcome so far (§5.2.4).
```

**This forces requirements back onto the corelib.** It **MUST**:

* let the generator drive encoding through the **same flush-callback / sink + buffer swap**
  mechanism (§5.1), so `serialize` works with a buffer smaller than the object;
* let the generator drive decoding through the **push-feed + pull-read / visitor**
  mechanism (§5.2), so a generated decoder consumes arbitrarily small chunks, binds each
  field straight into the object's member, descends into nested objects by either shape of
  §6.0, and resumes a half-built object across chunk boundaries.

#### 6.1.1 Canonical names for the generated-object layer (normative)

Generated types land in the **user's** namespace, and every extra spelling a port invents
— `serialize_to`, `to_bytes`, `from_bytes`, `decode_from`, `decode_into`, `marshal`,
`unmarshal` — is one
more name a developer must learn per language for an identical operation. **The set is
closed.** Adapt only casing/idiom (`try_decode` / `tryDecode` / `TryDecode`), never the
words.

| name | kind | purpose |
|---|---|---|
| `encode()` | instance | one-shot: produce the complete message as bytes |
| `decode(bytes)` | static / free | one-shot: build the object from a complete message; fails in the language's own way |
| `try_decode(bytes)` | static / free | the fallible form, for languages returning results rather than throwing; returns the object or the §6.3 error |
| `serialize(ostream)` | instance | streaming out: write the object's fields into a corelib output stream (§5.1) |
| `deserialize(istream, …)` | instance | streaming in: the per-field hook the decoder calls (§5.2) |
| `decoder()` | static / free | streaming in: obtain the generated reader that `feed`s chunks |
| `MAX_SIZE` | constant | the schema's worst-case encoded size; see §5.1.2 for how it is used |

* `encode` / `decode` are the **convenience** layer; `serialize` / `deserialize` are the
  **streaming** pair, and the convenience pair is a thin wrapper over it.
* A port **MUST NOT** add a second name for either — no `serialize_to` beside `serialize`,
  no `from_bytes` beside `decode`.
* Language-mandated extras stay allowed where the ecosystem requires them (a
  `Display`/`ToString`, a serde or `IXmlSerializable` bridge, an idiomatic constructor);
  they are not alternative entry points into the wire format.
* Anything below this layer — `feed`, `read_*`, `write_*`, `sequence_*` — is corelib API
  (§6) with its own names, and is not part of the generated object's surface.

### 6.2 Limits & Constants (normative)

| Constant | Value |
|---|---|
| `API_VERSION` | `1` |
| `ID_MAX` / field ID range | `0 .. 2,147,483,647` (2³¹ − 1) — **lower on a narrowed-width profile** |
| Unsigned value domain | 64-bit unsigned (`0 .. 2⁶⁴ − 1`) |
| Signed value domain | 64-bit signed (`−2⁶³ .. 2⁶³ − 1`) |
| Scalar value width | 64-bit by default — **may be 32-bit on constrained profiles** |
| `FIXLEN_MAX` | up to 2,147,483,647 — **may be 65,535 on constrained profiles** |
| `ARRAY_MAX` | up to 2,147,483,647 — **may be 65,535 on constrained profiles** |
| `MAX_DEPTH` | 255 (maximum nested-sequence depth) |

These are **format-wide ceilings**: properties of the wire format, identical for every
implementation, and exceeding one is `INVALID` (§5.2.2). They are **not** a protection
mechanism against a hostile sender — that is §6.2.1.

**The constrained-profile allowance.** Where the table says *may be 65,535*, a profile
built for constrained targets may lower the ceiling because carrying the full one costs RAM
per stream. It is one of the variations of §6.2.2, and carries that section's duty: a
profile that takes it **MUST state both ceilings**. (§5.1.4 runs the other way — there the
constrained profile is the strict one.)

**The narrowed scalar width.** By the same allowance, a profile built for 32-bit targets
**MAY** build the scalar value type 32 bits wide, to keep 64-bit arithmetic off a machine
that has none (§5.3.2). It carries the same duty to document what it chose, plus three
consequences the build does **not** get to choose:

* **`ID_MAX` shrinks with the width.** A field header is `(id << 3) | type` (§4.3),
  accumulated in the scalar value type, so a build of width `N` **MUST** cap the field id at
  the lower of the format ceiling and `(2ᴺ − 1) >> 3` — **536,870,911** at 32 bits. Leaving
  `ID_MAX` at `2³¹ − 1` under a narrower accumulator is a defect, not a liberty: the encoder
  truncates the id and reports success. The **constant the port exposes** carries the lowered
  value as well — a caller who reads `ID_MAX` and is handed a ceiling the build cannot reach
  has been told the wrong number.
* **Overflow is caught on both sides, never truncated.** A varint that does not fit the built
  width is `INVALID` (§5.2.2) — the §4.1.3 test applied at `N`, on the encoding rather than
  the decoded value — and an out-of-range id or value is `InvalidArgument` on encode (§6.3).
* **The interoperability limit is stated.** A 64-bit peer may legally emit an id or a value
  such a build cannot consume. That is an acceptable trade for a footprint profile only if
  the profile **states the width and the ceilings it chose** (§6.2.2).

**`ID_MAX` binds every header** — the value-bearing types, sequence *start*, and the
**sequence-end** marker alike. No **wire type** is exempt: that a sequence end's id is
discarded (§4.9) does not exempt it. The ceiling is stated over headers, not over headers
whose id a decoder happens to consult, which is what lets an implementation validate the id
where it decodes the header — one unconditional comparison — instead of carrying a
per-wire-type exception through every decode surface. A narrowed scalar width (above)
changes the **number** in that comparison; it does not exempt any header from facing it.

#### 6.2.1 Receiver-side technical limits (normative)

A field whose schema declares no bound (`maxlen`/`count` omitted — MESSAGE_SPEC §7.2) is
**unbounded**: the *message* declares no ceiling for it. That would let the **sender**
dictate the **receiver's** allocation, so every receiver **MUST** carry generic maximum
limits:

| limit | caps |
|---|---|
| `max_dyn_array_count` | elements in a schema-unbounded array |
| `max_dyn_string_len` | bytes in a schema-unbounded `string` |
| `max_dyn_blob_len` | bytes in a schema-unbounded `blob` |

**There is no unset state and no unlimited mode.** Unbounded by the schema is still
bounded by the receiver.

**The numbers and the allocation are not the codec's.** The limits come from generated
code, which knows the schema and the target. The *values* are a per-language,
per-deployment judgement — an element count trivial on a server is brutal in C — and how
much is allocated once a count clears its limit belongs to the generated layer too (§6.6).
This section fixes only **where the check happens** and **what its failure is called**;
SofaBuffers ARCHITECTURE §9.5 owns the rest.

**What the codec contributes** is the report and the category:

* it surfaces the **count** at the count/length header;
* for a **sequence array** it surfaces the **index** of the element in hand — a wrapper
  array's length is *highest present id + 1* (MESSAGE_SPEC §5.1), so the index is what has
  to be checked, there being no count header to check;
* the visitor decides. The codec never invents a limit of its own and never clamps to one.

**These limits are configuration, not schema:**

* chosen by the **implementer/deployment** to protect the system, independent of any
  message definition, and **not** part of the wire contract;
* exceeding one is a **policy rejection — a category distinct from `INVALID`**. The bytes
  are well-formed and decode successfully under a looser limit. An implementation **MUST
  NOT** report it as `InvalidMessage` and **MUST NOT** fold it into the `INVALID` outcome
  (§6.3);
* they **MUST NOT** be applied to a field the schema already bounds. There the schema
  bound governs and its violation is `INVALID` (MESSAGE_SPEC §7, §7.1) — a schema bound is
  a statement about *validity*, a receiver limit about *capacity*;
* two receivers configured differently reaching different outcomes on the same message is
  **not** an interop failure and **not** a conformance defect. Conformance testing
  therefore compares implementations configured with **identical** limits.

**Enforcement point (normative).** A limit **MUST** be enforced at the count/length
header — before the allocation it is meant to prevent — for the same reason `INVALID` is
decided there (§5.2.3). For a sequence array, whose length is not announced, that point is
the element **index**, checked before the container it indexes into is extended.

**Rejected, never clamped.** Silently materializing `limit` elements where the wire said
more is data corruption wearing a safety jacket.

**A skipped field is never capped.** A limit bounds an allocation, and a field the handler
skips allocates nothing — it is walked, not materialized (§6.7.2). A `max_dyn_*` limit
**MUST NOT** be applied to it, so a decode that steps over an over-cap field it was never
going to read stays `COMPLETE`. The check belongs at the count/length header of a field that
is actually **read**.

*(This is the receiver-capacity analogue of `MAX_DEPTH`: both cap what a receiver commits
on untrusted input. `MAX_DEPTH` is a fixed format ceiling and its violation is malformed
input; a `max_dyn_*` limit is deployment-configurable and its violation is not.)*

#### 6.2.2 What a profile may vary (normative)

A port **MAY** ship a build that trades capability for footprint. This is the **single list**
of those variations and the **single statement** of the duty that comes with them; the
sections that define each variation do not restate the duty, and this section does not
restate their reasoning.

**The gate.** A variation is permitted only where all three hold:

1. **It buys footprint on a constrained target** — RAM per stream, `.text`/`.rodata`, or
   arithmetic the machine does not have. Convenience, taste and API preference are not
   footprint.
2. **What it emits stays structurally well-formed** — the framing, headers, varints and
   lengths are exactly what a full build would produce, so every conforming decoder walks
   the bytes. A profile may narrow what it *accepts*, and §6.4 lets one waive a *payload*
   check; neither licenses a byte sequence outside §4.
3. **The README states it** (§9.7) — the numbers chosen, and what a conforming peer may
   legally send that this build cannot consume.

A build option that fails the gate is not a profile choice, it is a non-conformance. A
variation this document does not name is judged by these same three conditions.

**A variation need not be selectable.** Where a port is built one way permanently — a
heap-free encoder whose hold-back run is a fixed array below `MAX_DEPTH`, with no knob to
raise it — the duty is the same. What carries it is the **departure from the full profile**,
not whether a user can undo it; a port that offers no switch at all can still owe every row
of the table.

**The variations, and what each costs a peer.**

| variation | defined in | severity | the README states |
|---|---|---|---|
| hold-back depth below `MAX_DEPTH` | §6.0.1 | byte divergence | the bound it chose |
| lazy-sequence trio gated out | §6.0.1 | byte divergence | that the switch exists, and that it must match across the library and everything that includes it |
| `FIXLEN_MAX` / `ARRAY_MAX` at 65,535 | §6.2 | receive limit | both ceilings |
| scalar value width 32-bit | §6.2 | receive limit | the width, its `ID_MAX`, its value domain |
| `SOFAB_STRICT_UTF8` OFF or compiled out | §6.4 | validation divergence | that it is a non-strict build |
| `fp64`, fixlen, array or sequence support disabled | §5.3.2, §6.0 | type loss | which wire types the build does not carry |

**The four severities are not interchangeable** — they are what the README has to convey,
and they are why the duty is not a formality:

* **byte divergence** — the build emits a well-formed, non-canonical form that every decoder
  already accepts and normalizes. No peer is shut out; two encoders simply disagree about
  **bytes**, not about validity.
* **validation divergence** — the build accepts, and may itself emit, a payload a strict peer
  calls `INVALID`. The disagreement is about the *verdict* on identical bytes.
* **receive limit** — a message a conforming peer may legally emit is rejected. The bytes are
  fine; this build cannot take them.
* **type loss** — whole wire types are neither written nor read. The widest break, because it
  reaches **fields the build never reads**: the code that steps over a construct is the code
  the switch removed, so an unknown id carrying one is rejected rather than skipped, and
  MESSAGE_SPEC §7.3 cannot be honoured. Such a build talks only to peers that never emit the
  construct **in any field**, including one a later schema revision adds.

**Conformance is measured on the full build.** A variation may make the shared vectors
(§7.1) undecodable — a 32-bit build cannot read their 64-bit values — so a port that ships
one **MUST** still build and conformance-test the **unvaried** configuration in CI. §6.4
already says this for `SOFAB_STRICT_UTF8`; it holds for every row above. A profile is a
build a port offers, never the build it is judged by.

**The duty is the price of the allowance.** A profile that takes a variation without stating
it is not a footprint profile, it is an undocumented incompatibility — and the next port to
interoperate with it learns the bound by being rejected. §13 checks that every variation a
port takes is stated.

*(Not on this list: `MIN_OUTPUT_BUFFER` (§5.1.4), which runs the other way — there the
constrained profile is the **stricter** one — and build options no peer can observe at all:
diagnostics, descriptor sizing, and everything above the codec line of §6.1.)*

### 6.3 Error Handling (normative)

Every fallible operation reports one of the codes below. Names are canonical; adapt casing
and idiom, keep the meanings. (The C/C++ reference exposes them as `sofab_ret_t` / the
`Error` enum.)

| Code | Meaning |
|---|---|
| `None` / `OK` | Success. |
| `BufferFull` | Output buffer overflowed during encoding. |
| `InvalidArgument` | A field ID out of range, a scalar width that is not 1/2/4/8 bytes, a descriptor field type that does not exist, a **destination too short for the value it was handed** (§6.6.3) — or, with the strict UTF-8 check ON, a `string` value that cannot be encoded as valid UTF-8 (§6.4). |
| `InvalidMessage` | Malformed message while decoding: any §5.2.2 condition. Corresponds to the `INVALID` decode outcome. **Truncation is not `InvalidMessage`** — but input that is *both* malformed and truncated is, by the precedence of §5.2.3. |
| `LimitExceeded` | A configured receiver-side limit (§6.2.1) was exceeded on a schema-**unbounded** field. The message is **well-formed** — the same bytes decode under a looser limit — so this is **not** `InvalidMessage` and **not** the `INVALID` outcome. A terminal, receiver-local **policy** rejection. Never raised for a field the schema bounds. |

**Decode outcome vs. error code.** A decoder's per-`feed`/`decode` result is the
three-valued **outcome** (§5.2), *not* a code from this table. `INVALID` corresponds to
`InvalidMessage`. `INCOMPLETE` is **not** an error and **MUST NOT** be reported as
`InvalidMessage`; it is surfaced to the caller, who judges it per its own framing, and
there is no `finish` step that converts it (§5.2.4). This table covers the *other* fallible
operations — encoding and argument checks.

**A type-mismatched read is not an error at all.** Binding a read whose declared type
contradicts the wire is the MESSAGE_SPEC §7.3 case: the field **MUST** be skipped like an
unknown id, leaving the destination untouched. It is neither `InvalidMessage` nor an
argument error, and a decode that meets nothing else stays `COMPLETE`. There is therefore
**no** code for "invalid usage": every remaining caller mistake is `InvalidArgument` and
every remaining malformed input is `InvalidMessage`.

**`LimitExceeded` is the one decode-path exception to that split.** It terminates a decode
on *well-formed* input, and the three-valued outcome has no value for "valid, but more than
I am configured to accept". An implementation **MUST** keep the two distinguishable to the
caller — a limit rejection means *"raise my limit or the sender must send less"*, `INVALID`
means *"these bytes are broken"*. **How** it is surfaced is left open: either a **fourth
decode outcome**, or a terminal failure carrying the `LimitExceeded` code on the error
channel. Either way it **MUST NOT** be reported as `InvalidMessage`.

**Three ways a value can be refused, and only one means the bytes are bad (normative).**

| the value | who knows | code |
|---|---|---|
| exceeds a bound the **schema** declares — `count`, `maxlen`, a declared integer width | generated code (MESSAGE_SPEC §7.1) | `InvalidMessage` |
| exceeds a **configured receiver cap** on a schema-unbounded field (§6.2.1) | generated code | `LimitExceeded` |
| broke neither, but does not fit the **destination the caller handed over** (§6.6.3) | the codec | `InvalidArgument` |

The third is a mistake in the **call**, not a property of the message or of the deployment,
and the other two codes each say something untrue about it. `InvalidMessage` would mark a
well-formed message malformed — the same bytes decode for a caller who passes a larger
destination, and no §5.2.2 condition is present. `LimitExceeded` would promise a limit to
raise that was never configured. A port **MAY** refine it into a language-specific condition
— a range or capacity error of its own — as long as that condition **refines
`InvalidArgument`** rather than standing beside these five as a sixth category.

**Extending the set.** This is the common baseline. Language- or platform-specific
conditions **MAY** extend or refine it — an I/O error from a stream sink, an allocation
failure in a managed runtime, an encoding error from a standard library — as long as the
baseline meanings are preserved.

**Exceptions vs. return codes:**

* where exceptions are the **default, idiomatic** mechanism (Python, Java, C#), throwing is
  fine — map the codes onto exception types;
* where they are **unavailable, costly, or commonly forbidden** (C, embedded / `no_std`,
  real-time or kernel targets, `-fno-exceptions` builds), **do not use exceptions**: return
  a status code or a result/`Result`-style object on the hot path, so constrained callers
  never pay for them.

### 6.4 String Validity: UTF-8 (`SOFAB_STRICT_UTF8`, normative)

A `string` payload is **UTF-8** (§4.6); `blob` is the type for opaque bytes (the
producer-side rule lives in MESSAGE_SPEC §8). A `string` whose bytes are not valid UTF-8 is
malformed: reject it — on decode as `INVALID` (§5.2.2), on encode as `InvalidArgument`
(§6.3).

Validation is gated behind one canonical option, **`SOFAB_STRICT_UTF8`** (adapt casing). It
is a **validation policy, never a wire-format switch**: it decides accept-vs-reject only and
never changes how valid data is encoded, so two peers with different settings interoperate
on all valid data.

#### 6.4.1 The two states

**ON (default) — invalid UTF-8 is rejected, symmetrically:**

* *decode*: an invalid-UTF-8 `string` payload **that is read** is `INVALID` — the same
  terminal class as any other malformed-message condition, not a length/limit error;
* *encode*: a `string` value that cannot be encoded as valid UTF-8 — non-UTF-8 bytes in a
  byte-container type, an **unpaired surrogate** in a UTF-16/Unicode type — is refused with
  `InvalidArgument`. Encode-side validation is what enforces MESSAGE_SPEC §8's producer-side
  **MUST NOT**: without it, a strict ecosystem's own encoders can still emit bytes its
  decoders reject.

**OFF (opt-out) — validation is waived, but the permitted behaviour is pinned, not
implementation-defined: raw or reject, never silent lossy.**

| target string type | behaviour with the check OFF |
|---|---|
| **byte containers** (C `char[]`, C++ `std::string`, Go `string`, Zig `[]const u8`) | store the wire bytes **verbatim** — untranscoded, but still **copied** into the caller's destination (§6.7.3). Interpreting code points is the application's job. **These targets MUST expose the option.** |
| **Unicode strings** (Rust `String`, Java/C# `string`, JS strings, Python `str`) | cannot hold non-UTF-8 bytes; their only non-mutating option is the **strict/fatal** constructor, so they are **always strict**. The option is a no-op and **MAY be omitted entirely**, documented as always-ON. |

**Silent replacement is forbidden in every mode (normative).** An implementation **MUST
NOT** substitute `U+FFFD` or any replacement, drop bytes, or produce an empty/absent value
for an invalid-UTF-8 `string`, in either direction, in any mode (MESSAGE_SPEC §8). Platform
default encoders are often lossy — Java's `getBytes(UTF_8)` and JavaScript's `TextEncoder`
replace unpaired surrogates with `U+FFFD`. Use the strict/fatal variants.

#### 6.4.2 Default and placement

`SOFAB_STRICT_UTF8` defaults to **ON**, which makes the default configuration the one the
shared vectors (§7.1) and the differential fuzzer run under. For Unicode targets strictness
is already paid for by the mandatory transcode; for byte containers a proper validator is
cheap next to decode itself.

**Constrained/footprint profiles MAY default to OFF or compile the check out entirely**
(zero `.text`/`.rodata` cost when OFF) — a §6.2.2 variation, so the README **MUST** say the
build is non-strict: it accepts, and may itself emit, a `string` payload a strict peer
rejects. The target's CI **MUST** still build and conformance-test the check-ON
configuration.

**Where the knob lives** (byte-container targets) follows where the corelib already keeps
its configuration: *compile-time* (`#define`, a Zig build feature) for footprint targets;
*runtime option* (a decoder/encoder configuration field, as in Go) next to the existing
decode limits. C++ may use either.

#### 6.4.3 The `utf8_valid` primitive

Where **generated code** — not the corelib — materializes the string in a **byte-container**
target (Zig), the corelib exposes `utf8_valid(bytes) -> bool` and the generator emits an
**unconditional** call to it. The gate lives inside the primitive: it folds to `true` when
compiled OFF and reads the runtime option otherwise.

* Flipping the flag therefore never requires regenerating code.
* Generated code is identical across build configurations.
* In codegen-materialized **Unicode** targets (Rust, Java, C#) generated code uses the
  strict constructor; no primitive is needed.

**Validator correctness (normative).** `utf8_valid` — and any corelib-internal check — is a
real UTF-8 validator, not a byte-range shortcut. **This is a security surface.** It **MUST**
reject:

* overlong encodings, including `C0 80` (Java's "Modified UTF-8" NUL);
* surrogate code points `U+D800`–`U+DFFF`;
* code points above `U+10FFFF`.

Most languages have a stdlib validator to gate; C and C++ need a hand-written, tested one.

**Embedded `U+0000` is allowed.** NUL is valid UTF-8 and representable in the length-framed
payload (§4.6); the validator **MUST NOT** reject it, while the overlong form `C0 80`
**MUST** be rejected like any other overlong encoding. *(Non-normative interop note:
NUL-terminated consumers truncate at the first NUL. The corelib API is length-delimited, but
producers targeting such consumers SHOULD avoid embedded NUL or use `blob` —
MESSAGE_SPEC §8.)*

#### 6.4.4 Cross-chunk semantics (normative)

UTF-8 validity is a property of the string field's **complete payload** — the fixlen length
is known up front — and **a chunk boundary MUST NOT affect the outcome.** A decoder MAY
validate incrementally provided it carries validator state across `feed` calls; no assembly
buffer is required.

| situation | outcome |
|---|---|
| multi-byte sequence split at an **end-of-chunk** | `INCOMPLETE` — a well-formed prefix that more bytes may complete. Reporting `INVALID`, or dropping the string, is the §5.2.1 anti-folding violation. |
| multi-byte sequence truncated at **end-of-payload** (declared length reached mid-sequence) | `INVALID` — no further bytes belong to this string |
| a byte that can neither begin nor continue any valid sequence (`0xFF`, a bare continuation byte) | `INVALID`, but reported **at payload completion**, not before |

That last row is the one place where §5.2.3's precedence does **not** pull the verdict
forward. A decoder **MUST NOT** report `INVALID` mid-payload for such a byte while the
declared length has not been reached; that input is `INCOMPLETE` until the payload ends.

*Why:* this check is not a property of the wire. `SOFAB_STRICT_UTF8` has a normative OFF
mode in which the same bytes are accepted, and validation runs only where a `string` is
**materialized**, never on skip — so the same payload is already valid or invalid depending
on a build flag and on whether the handler read it. Letting its *timing* decide the verdict
as well would make two conformant decoders disagree on accept-vs-reject, which
MESSAGE_SPEC §7.1 forbids and which this section's opening promise rules out.

#### 6.4.5 Skipped fields are never validated (normative)

Skipping stays what it is everywhere else: a length jump over bytes that are not inspected
(§5.2). UTF-8 validation runs **only where a `string` is materialized** — read into a
destination — never on skip, in any mode.

* Wire validity of unread content is the **producer's** responsibility (MESSAGE_SPEC §8,
  enforced by the strict encode side). Protobuf treats unknown fields the same way.
* The decode outcome may therefore depend on which fields the handler reads. The shared
  vectors and the differential-fuzzer drivers read **every** field, so conformance results
  stay deterministic.
* With exactly two per-field intents (§6.7.2), a wanted field is always **read** and
  therefore always validated; only a field nobody asked for takes the skip path.

**Conformance testing and the differential fuzzer run with the check ON**, which is also the
shipped default, so every implementation agrees that an invalid-UTF-8 `string` is rejected.
A deployment that needs maximum throughput and controls both ends may switch it off;
cross-implementation interop requires it on.

### 6.5 Float Bit-Exactness: the fp32 signaling-NaN hazard (normative)

§4.6 requires every float — `NaN` included — to round-trip **bit-for-bit**. For `fp64` this
is free: a native 64-bit double holds all 64 bits verbatim. **`fp32` carries a
representation hazard**, and this section makes the guard against it normative.

**The hazard.** IEEE-754 distinguishes two kinds of `NaN` by the most-significant mantissa
bit (the *quiet* bit): quiet has it set, signaling has it clear with a non-zero payload.
Widening `fp32` to a wider float is **not** bit-preserving for a signaling NaN — the IEEE
widening **sets the quiet bit**:

```
fp32 sNaN   0x7F80_0001   ── widen to double ──▶   qNaN   0x7FC0_0001
                    ▲ quiet bit 0 (signaling)               ▲ quiet bit 1 (quiet)
```

The payload is destroyed **the instant the value passes through the wider float**, and no
later code can recover it. A decoder that carries an `fp32` to the consumer or to its own
re-encode as a widened double loses the sNaN and changes the wire bytes — a §4.6 violation.

**Who must act:**

| target | obligation |
|---|---|
| **native `fp32` type** (Rust `f32`, C, C++, Go, Java, C#, Zig `float`) | **nothing to do.** The natural implementation keeps the payload in that type end-to-end — a 4-byte load/store, no `fp64` in the round-trip path — so an sNaN round-trips on its own. Just do not *gratuitously* widen to double and back. |
| **double-only** (JavaScript/TypeScript, Python, Dart, Lua default build, and any language whose sole float is a double or that materializes `fp32` by widening) | **MUST** provide a raw-wire-bytes path (below) |

**Requirement (normative).** The §4.6 outcome is universal: for **every** implementation,
decode → re-encode of any `fp32` payload (signaling NaN included) **MUST** reproduce the
exact 4 wire bytes, at **every** `fp32` position — a **scalar** `fp32` (§4.6) **and** each
element of an **`fp32` array** (§4.8). What differs is only *how* a target meets it.

Double-only targets:

* **MUST** provide a **raw-wire-bytes** path for bit-exact consumers (transcode,
  round-trip, any re-encode) that re-emits those bytes **verbatim**;
* **MUST NOT** re-encode an `fp32` from the widened value;
* **MAY** keep the convenience **value** handed to a value consumer a widened double — it
  only needs to know the value is `NaN`.

**This holds wherever an `fp32` reaches the caller** — the visitor is the only decode
surface (§5.3.1), so there is one place to get it right, and a port that guards its
round-trip path but not its value path is the defect class this section exists to prevent.

`fp64` never needs the raw path in any language.

**How (double-only targets).** Deliver the `fp32` payload the way a `string`/`blob` payload
is delivered — raw little-endian wire bytes copied into the caller's storage, or a 32-bit
bits accessor — *alongside* the convenience value, and re-encode by writing those bytes directly (never
`setFloat32` or reinterpret-from-double). Gate the raw channel as opt-in if per-element
raw delivery would burden value-only array decoding.

**Testing (normative).** Because JSON vectors cannot represent `NaN` (§4.6, §7.1), this is
verified by an **implementation-level** suite, not the shared vectors: assert that a
signaling, a quiet and a negative `fp32` NaN each round-trip **bit-for-bit** at both a
scalar and an array position, across decode → re-encode **and** any materialized walk, on
**every** decode surface. The SofaBuffers differential harness (Crucible) additionally
checks that all language drivers agree bit-for-bit on every `fp32` NaN.

### 6.6 Memory: the codec is heap-free (normative)

**A corelib's codec MUST be heap-free.** It performs **no** dynamic allocation of any kind:
no `malloc`, `realloc`, `free`, `new`, `delete`, no allocator call, no growable container of
its own, no arena, no scratch it sizes at run time — on either side, on any path, in any
build configuration. Every byte it reads, writes or reports on lives in storage the
**caller** supplied, or in **fixed-size state whose size this document fixes** (§6.6.2).

This is stricter than the rule it replaces, and deliberately so. An earlier revision
forbade only memory *whose size the message decides*, which left an implementation free to
allocate as long as the number came from somewhere else. Two rules were then needed — one
about the mechanism, one about the size's origin — and the second could only be checked by
measurement. **One rule replaces both:** the codec does not allocate. A number that never
reaches an allocator cannot be exploited by whoever chose it.

Both of these are now violations, and the second is the one ports got wrong:

| shape | verdict |
|---|---|
| the codec calls its language's allocator, for anything at all | **violates** — regardless of what determined the size, with one narrow exception (§6.6.2) |
| the codec calls nothing itself but **requires a growable destination** and grows it, from a wire count or otherwise | **violates** — it moved the allocator call one type away, where a source-level audit no longer sees it |

**One-time construction is the boundary.** The codec's own fixed-size state has to live
somewhere, and in a managed language the object holding it is itself heap-allocated.
**Constructing** the encoder or decoder — sizing its state from this document's constants —
is the caller's act, happens **once, at setup**, and MAY allocate. The prohibition binds
everything **after** construction: `write`, `feed`, `flush` and every path they reach
perform **zero** allocations. A codec that allocates per message, per field or per chunk has
broken the rule; one whose constructor allocated its fixed-size state once has not — nothing
on the wire chose that size, and nothing after setup allocates again.

**Where dynamic memory is otherwise allowed:** in the **static helper layer** only (§6.6.1), and
only where the codec does not call into it. A helper that the codec invokes on the decode or
encode path is part of the codec for the purposes of this section, whatever file it lives in.

What this buys, and what was previously argued port by port: a firmware target and a server
target run the *same* code rather than two profiles of it; a caller can bound a decode's
memory by construction instead of by measurement; and "who frees this" stops being a
question a port answers in its README.

#### 6.6.1 Scope: the codec, not the package

This section binds the **codec** — the encoder and decoder that touch wire bytes.

It does **not** bind the **static helper layer** that ships alongside: the reassembly
buffers, sequence collectors and array builders a port holds so the generator need not emit
them into every generated package (SofaBuffers ARCHITECTURE §8). That code is the generated
layer's, and the generated layer allocates. It lives in the corelib repository for reuse,
not because it is part of the codec, and **a reader auditing §6.6 must not mistake one for
the other.**

**The boundary is the call graph, not the directory.** A helper is outside the codec only if
**no codec path calls it**. The generated layer calls the helper, and the helper calls the
codec — never the other way round. A port that lets its decoder reach into an allocating
helper has put allocation back into the codec, however the files are arranged.

**The generated layer allocates; the codec does not.** §5.1.2 states this for encode and it
reads identically for decode: the generated object knows the schema, sizes and owns the
storage each field lands in, then drives the codec over it like any other caller. A codec
that needs a value materialized asks its caller for the room; it does not take it.

#### 6.6.2 What is and is not an exception

**Reassembly is not an exception.** A payload split across fed chunks has to be joined
somewhere (§5.2). That somewhere is storage the caller supplied — the codec copies each
piece into it as the piece arrives, which the chunk-lifetime rule (§6.0) already forces. A
codec **MUST NOT** grow a private accumulator instead. A *helper* that does exactly that on
the caller's behalf is the static helper layer of §6.6.1 and is not this section's business.

**Bounded working state is allowed because it is atomic, not because it is small.** A
fixed-size parse stack, the `MAX_DEPTH` counter, a held-back header (§6.0.1), a partial
varint, a landing zone for a scalar split across a chunk boundary — all exist so the
caller's destination is written **exactly once, complete**. A codec that wrote a
half-arrived value into the destination and patched it up later would expose a state no
caller can reason about. Their size comes from this document, so the message cannot choose
it, and *that* is what makes them conformant. Being small is a consequence, not the licence.

This section **prescribes no design** for such state: a scalar shift register, a fixed
array, a byte-at-a-time carry are all correct. A port picks what its language makes cheap.

**Language-forced handles are the one exception.** Some languages will not let a codec
express an operation at all without allocating an object first: the only bulk-copy or
bulk-write primitive takes a *typed handle* — a view, a slice object, a span — instead of a
pointer and a length; the only way to name a region of the caller's buffer is a wrapper over
it; the runtime hands out no raw pointer to wrap in the first place. Where that is the case,
a codec **MAY** allocate such a handle. The language is charging for the *mechanism*, and
forbidding it would forbid the copy §6.7 requires — no port in that language could conform.

Two properties make an object this exception rather than an ordinary violation:

* **it carries no message bytes** — it addresses storage the caller supplied, or nothing at
  all. A value the codec materialized into an object of its own is not a handle, whatever
  its type;
* **no wire number sizes it** — a handle over a thousand bytes costs what a handle over ten
  costs. The message cannot choose how much is allocated, and that is the property §6.6
  protects.

Beyond those two this section **prescribes nothing**. How many such objects a port
allocates, and whether it allocates one per call or keeps one and reuses it, is an
optimization it makes for its language — not a conformance question. §6.7 is untouched
either way: the handle is the codec's mechanism and never becomes a value the caller sees.

What the port owes instead is visibility: the handles are **itemised in its README** (§9.6)
and **pinned by a test**, so that an allocation nobody listed fails the measurement of
§6.6.4 rather than hiding behind this paragraph.

#### 6.6.3 Consequence for the callback surface

A callback delivering a **materialized aggregate** — a whole `string`, a whole byte array, a
whole element list — obliges the codec to build that value, and the only size available to
build it from is the wire's. Ports meeting this section therefore deliver an aggregate
either:

* **in pieces**, with the payload's total, this piece's offset, and the caller's own buffer
  as arguments; **or**
* **into a destination the caller hands back** after being told the announced count, with
  the codec refusing a destination too short rather than growing it. That refusal is
  **`InvalidArgument`** (§6.3): the message is well-formed and within every bound it
  declares — what does not fit is the storage this caller offered.

Scalar callbacks are unaffected: they carry a value, and a value is not storage.

#### 6.6.4 Checked both ways

The rule is now about the **call**, so the source is evidence again: no allocator call on a
codec path, and no codec path into an allocating helper (§6.6.1).

Source inspection alone is still **not sufficient**, because an indirect allocation through a
caller-supplied container leaves no `malloc` in the source to find. Conformance therefore
requires **both**:

* **read** — no allocation primitive is reachable from a codec entry point, apart from the
  language-forced handles §6.6.2 allows;
* **measure** — an allocation count, or the heap high-water mark, over a complete encode and
  a complete decode, **measured after the codec's one-time construction**, which **MUST** be
  zero apart from those handles, which **MUST** be itemised (§13).

### 6.7 No views: the codec copies (normative)

**A corelib MUST NOT expose a zero-copy view of any decoded value.** Every value the codec
delivers is **copied into storage the caller supplied** — a `string`, a `blob`, a scalar, an
array element alike — on the one-shot path exactly as on the streaming one. There is no
payload-position getter, no borrowed slice, no "valid until the next feed" value, and no
build option that reinstates one.

An earlier revision let a port report a payload's byte position so that a caller could place
a view over it. That is withdrawn, and the reason is the same one §6.6 rests on: **the caller
owns the memory, and the codec holds none.**

* A view is a claim about **lifetime** — "these bytes stay where they are, and stay valid,
  until some later moment". A codec that keeps no storage of its own has nothing to make that
  claim about. It would be asserting a property of memory it neither allocated nor controls.
* The claim is also **not checkable**. Its two conditions — the payload is complete, and the
  message reached `COMPLETE` — are conditions on the *caller's* discipline, and a port that
  hands out a position cannot enforce either. A rule an implementation cannot enforce is a
  rule that is broken in the field and never reported.
* It **split one decode surface into two**, one that materializes and validates and one that
  does neither, and the difference between them was invisible in the shared vectors — they
  fire only on a value the decoder is asked about.

**What replaces it:** nothing is needed. A caller that wants to avoid a copy keeps the input
bytes it fed and indexes into them itself; it knows what it fed and how long that memory
lives, which the codec never did.

#### 6.7.1 The one-shot path has no exemption

`decode(buffer)` copies too. That the caller supplied the whole buffer, and keeps it alive
across the call, would make a view *safe* — but it would also make the port's decode
behaviour depend on which entry point was used, so that the same schema carried different
memory obligations on the one-shot path than on the streaming one. That divergence is what
§6.6 and §9.6 exist to end.

#### 6.7.2 Consequences for the per-field intents

There are exactly **two** per-field intents, and a port **MUST NOT** add a third:

| intent | codec | caller |
|---|---|---|
| **read** | materializes into the caller's destination, and validates | takes the value |
| **skip** | neither materializes nor validates (§6.4.5), and is never capped (§6.2.1) | ignores the field |

The `examine` intent of the earlier revision existed only to keep a *viewed* field from
being routed through `skip` and thereby escaping UTF-8 validation. With views gone, a wanted
field is always **read**, so it is always validated, and the escape it guarded against
cannot occur.

#### 6.7.3 Strings with the check OFF are still copied

§6.4.1 lets a byte-container target store wire bytes **verbatim** when `SOFAB_STRICT_UTF8`
is OFF. Verbatim means *untranscoded*, not *uncopied*: the bytes are copied into the
caller's destination unchanged. There is no mode in which the destination aliases the input.


---

## 7. Mandatory Unit Testing

Every `corelib-<lang>` **MUST** ship unit tests, and those tests **MUST** validate against
the shared, language-agnostic conformance suite. The test folder follows the language's
idiomatic convention — `tests/` in Rust and Python, `src/test/` in Java/C#, `<pkg>_test.go`
files in Go.

### 7.1 Use the Shared Test Vectors

* **Copy `test_vectors.json` from `corelib-c-cpp`** into the new repo's `assets/` folder
  (§8); the suite reads it from there. Never hand-write a divergent copy — `corelib-c-cpp`
  **generates** it and is its source of truth (§2).
* **The authoritative format description is `test_vectors_README.md`**, next to the file in
  `corelib-c-cpp/assets/` (§2). For top-level keys, per-vector fields, the `fields[]`
  operations and their parameters, and how floats/blobs/offsets are represented, follow
  that document rather than any copy — so this plan can never drift from the generated
  format.
* **The file is not only vectors.** It carries top-level blocks beside them:
  * `invalid_utf8` — negative cases for §6.4;
  * `sequence_growth` — the cases of §7.2 item 8, keyed by a sequence of element ids
    rather than by a byte string, which is why they cannot be vectors.

  A port runs **every** block its `requires` gating does not exclude.
* **Vector categories to cover:**
  * scalars — unsigned, signed, bool, fp32, fp64, string, blob;
  * field-ID boundaries — `0` and `2,147,483,647`;
  * **all three array wire types** — unsigned-integer (`u8..u64`, `0b011`), signed-integer
    (`i8..i64`, `0b100`), and fixlen/float (`fp32`/`fp64`, `0b101`) including `±0` and
    `±inf`;
  * sequences — nested, with scalars and arrays; structs and unions;
  * one large composite message mixing everything.

### 7.2 Required Test Kinds

**1. Vector encode** — replay each vector's `fields` through your encoder at the given
`offset`; assert the bytes equal `serialized.hex`.

**2. Vector decode** — feed `serialized.hex` into your decoder; assert the recovered
fields/values match `fields`.

**3. Roundtrip** — encode → decode → compare, for representative messages.

**4. Chunked streaming** — the defining requirement:

* **Encode into a buffer of exactly `MIN_OUTPUT_BUFFER` bytes**, driving the sink
  repeatedly; assert the concatenated output is byte-identical to the one-shot output. The
  port's own declared minimum, not merely "smaller than the message": that is the size that
  proves the constant real. Cover a `string` or `blob` payload longer than the buffer, so
  the divisible-run path is exercised whatever the declared value is.
* **Reject a buffer below the minimum** — install one **with a sink**, `buflen - offset`
  one byte short; assert it fails **there**, by the port's out-of-range mechanism, not
  partway through a message (§5.1.4). A port declaring `1` tests the zero-length buffer.
  Pair it with the converse: the same undersized buffer **without** a sink is accepted and a
  message that fits encodes into it — the minimum **MUST NOT** become a floor on the
  one-shot path.
* **Encode across a taking sink** — a callback that installs a *different* buffer on every
  call, scrubbing the one it was handed before returning; assert the output still equals the
  one-shot output (§5.1.5). An encoder that kept writing into the buffer it gave away reads
  back the fill pattern, and the `MIN_OUTPUT_BUFFER` test above would not notice, since that
  sink copies and returns. Pair it with a **copying** sink that returns without installing
  anything and assert the same output, covering both halves of the contract.
* **No foreign memory, ever** — encode a `blob` several times the buffer size and assert
  that **every** callback argument lies within the installed buffer (compare identity, or
  that the pointer falls inside it). Pass-through is forbidden (§5.1.6), so this must hold
  on every flush of every message, with no permission flag to set and no exemption to
  claim.
* **Decode one byte at a time** (and in odd-sized chunks); assert the result is identical to
  feeding everything at once. This proves the state machine suspends and resumes at any byte
  boundary.
* **Overwrite every chunk after `feed` returns** — scrub it with a fill byte, or free it —
  and assert the decoded message is unchanged. This makes the chunk lifetime of §6.0 a
  checked property rather than a stated one; nothing else in this list would notice a
  decoder that kept a slice into a fed chunk.
* **Overwrite the one-shot buffer too** — run `decode(buffer)`, scrub the whole buffer, and
  assert the decoded message is unchanged. The one-shot path has no view exemption
  (§6.7.1), and this is the test that proves it; a port that borrows from the buffer it was
  handed passes every other item on this list.

**5. Malformed input** — every §5.2.2 condition **MUST** return `INVALID`, never crash:
an overlong varint, an unbalanced sequence end, an oversized id/length/count, nesting past
`MAX_DEPTH`, a reserved fixlen subtype. Cover the oversized id on a **sequence-end** header
too, not only on a value-bearing one: §6.2 admits no exception, and an implementation that
validates the id only in the branches that *use* it passes the value-bearing case and misses
this one.

**5b. Tolerance** — input that is non-canonical but well-formed **MUST** decode to the value
it denotes and re-encode canonically, never `INVALID`:

* a non-minimal varint (§4.1.2) at a field header, a `fixlen_word`, and an element count;
* a **sequence-end header whose id is non-zero but within `ID_MAX`** (§4.9), which **MUST**
  decode as an ordinary sequence end and re-encode as `0x07`.

These are the cases where a decoder is *stricter* than the format allows — the mirror of
item 5, and the ones a majority-vote conformance check cannot catch, since implementations
may be uniformly too strict.

**6. Truncation** — a message cut short mid-field (a lone dangling `0x80`, a fixlen payload
shorter than its declared length, an unclosed sequence) **MUST** return `INCOMPLETE`, not
`INVALID` and not `COMPLETE`; feeding the missing bytes then completes it, and no `finish`
step promotes it to an error (§5.2.4).

Cover a **`fixlen_word` cut after its first byte** with that byte carrying a **reserved
subtype** (`0x4`–`0x7`): the subtype is already settled by the low 3 bits, so an
implementation that evaluates it early answers `INVALID` where §4.1.1 requires `INCOMPLETE`.
Nothing else in this list exercises the no-partial-evaluation rule — the dangling `0x80`
carries no settled sub-field to peek at.

**7. Skip** — decode while ignoring some fields and whole sub-sequences; assert correct
resync on the following field.

**8. Sequence-array growth** — replay the `sequence_growth` cases from `test_vectors.json`
(§7.1). A sequence array's length is *highest present id + 1* (MESSAGE_SPEC §5.1), so its
size is known only when the array ends and its container grows as elements arrive — **in
the static helper / generated layer (§6.6.1), never in the codec** — the one
allocation shape where growth is conformant (ARCHITECTURE §9.5; everything with a count or
length on the wire ahead of its payload checks that word and allocates exactly it, once).

Nothing else in this list reaches it: two ports that grow differently emit identical bytes
and reach identical outcomes, so §7.1's vectors are structurally blind to it.

Assert, per case, the resulting **container length** and the **outcome** — no allocator
instrumentation, which is what makes these cases portable:

* the element **index** is the bound: `id` at the cap-1 boundary decodes; `id` at the cap is
  `LimitExceeded` (§6.2.1) and allocates nothing first;
* an id gap below the cap is filled with the element default and does not shorten or shift
  the array;
* after a rejected id the container is **not** left partially extended, and a lower id
  delivered afterwards still lands correctly.

Growth **geometry** — extending to at least `id + 1` rather than exactly `id + 1`, so a
sparse array does not cost O(n²) copies — is the one property here needing the language's own
allocation-counting facility. Test it where the language offers one; where it does not, say
so in the port's README rather than reporting the case as passed. A port that never grows (a
statically bounded profile) is excluded by the block's `requires` gating and states that
instead.

### 7.3 Coverage

Match the bar set by existing ports: wire a coverage job into CI and surface a badge in the
README. **Expected coverage is >90%.**

---

## 8. Assets Requirement

Copy into the new repository's `assets/` folder:

| File | From | Used by |
|---|---|---|
| `sofabuffers_logo.png`, `sofabuffers_icon.png` | `documentation/assets/` | the README header (§9.1) |
| `test_vectors.json` | `corelib-c-cpp/assets/` — generated there, authoritative | the test suite (§7.1) |

`test_vectors_README.md` stays in `corelib-c-cpp` and is the authoritative description of
the vector format; do not copy it. Raw links are in §2.

---

## 9. README Format

Every `corelib-*` README follows the **same shape**, so a reader who knows one port's
README can navigate any other. Reproduce the structure below, swapping in the target
language's specifics.

**Before editing a README, read the corelib's actual source code.** Every fact, command,
version number, dependency, feature flag and API name the README states **MUST** match the
code as it stands today. Fix anything stale, inaccurate or misleading.

#### 9.0.1 The README states; it does not argue (normative)

It carries **facts** — what the library is, what it requires, what to type, what a call
looks like, what the numbers are. It does **not** carry the reasoning behind them. Three
kinds of prose belong nowhere in it:

| out | why |
|---|---|
| **rationale** — why an API has its shape, why a trade-off went one way | there is exactly one place for it: the table in §9.3, which is a table precisely so it cannot grow into an essay |
| **anticipated objections** — text defending a decision against a reader who has not raised it | a reader who wants that argument is looking for the spec |
| **restatement of the specification** | `MESSAGE_SPEC.md` and this document are normative and one link away. A paraphrase creates a second source that drifts, and the drift stays invisible until someone trusts the wrong copy. |

#### 9.0.2 Sections: fixed order, and what may be added

* **Do not change the section ordering**, and do not invent new sections. The prohibition
  binds at **every heading depth**, not only `##` — a new `###` or `####` inside a
  sanctioned section is the usual way this shape is lost, and it is how a README reaches
  thirty headings without a single new top-level one.
* **A port MAY still add a section for something genuinely its own** — a feature-flag table,
  packaging for its ecosystem, the target list of a multi-platform build. Nine of the twelve
  corelibs independently grew a `## Feature flags`, and that convergence is what a gap in
  this section looks like, not what creep looks like.
* The prescribed sections keep their names and order; an addition never displaces or
  replaces one.
* **The test for an addition is the same as for everything else here:** if what fills it is
  **fact** — switches, versions, coordinates, commands, targets — it belongs, and a port
  that has such things should say so under its own heading rather than smuggling them into
  a neighbour. If what fills it is **reasoning**, it does not belong, and giving it a
  heading does not change that.

#### 9.0.3 The deletion test (normative)

**A fact may leave the README only if it is present in the generated API documentation.** If
it is nowhere else, it is not deleted — it is written into the doc comments first and
removed here afterwards. Anything found to be in neither place is **reported**, never
quietly dropped.

Note the asymmetry, because it is the whole point: **cutting justification never costs a
fact.** Every statement, every code example and every table stays. Nothing here licenses
removing a version number, a dependency, a command or an example, and a shorter README that
lost one of those is a worse README, not a better one.

The sections, in order:

### 9.1 Generic header block (centered)

* Centered logo: `<p align="center"><img src="assets/sofabuffers_logo.png" alt="SofaBuffers" height="140"></p>`
* `# SofaBuffers`
* Tagline: `<b>Structured Objects For Anyone</b><br>` + `<i>... so optimized, feels amazing.</i>`
* A link back to the GitHub organization.

### 9.2 `## SofaBuffers <Language> library`

The opening section, in this order:

* **Badges** — CI, coverage, and a **Docs** badge. The Docs badge links to the API reference
  on GitHub Pages (§12.2) and is the *only* pointer to API documentation the README carries.
* **GitHub link** — to this port's repository / the organization.
* **Short summary** — one paragraph on what makes *this* library special: the language's
  selling points, the streaming guarantee, the small footprint, cross-language
  compatibility.
* **Requirements** — minimum runtime / toolchain version, plus the install command
  (`cargo add`, `pip install`, `go get`, …).
* **Dependencies** — every non-optional dependency and its minimum version, or an explicit
  "no runtime dependencies". Keep current as the library evolves.

### 9.3 `## Why this design`

A two-column table mapping design goals — streaming output, streaming input, zero
unnecessary copies, low/no allocation on the hot path, small footprint, type safety,
cross-language compatibility — to how *this* implementation achieves them. Keep the table
format; it **MUST** stay parallel across ports.

**The table is the whole section**: no prose paragraph above or below it, one line per cell.
This is the README's only sanctioned rationale, so it is where the pressure lands once the
rest of the document is closed to it (§9.0.1) — and prose beside the table is how that
funnel leaks.

### 9.4 No API-documentation section

**There is no API-documentation chapter.** The **Docs** badge (§9.2) is the single entry
point to the generated API reference. Do **not** add `## Source documentation`,
`## API reference`, `## API documentation` or similar, and do not dump generated doc content
into the README.

### 9.5 `## Usage`

Concise, runnable examples in the language's idiomatic pattern, for each of:

* **Simple encode** — build a small message, produce its bytes.
* **Simple decode** — parse bytes back into values.
* **Streaming a message larger than the buffer** — drive the sink with an output buffer
  smaller than the message.
* **OStream** — the output-stream / writer-sink wrapper.
* **IStream** — the input-stream / push-feed wrapper.
* **Generator** — generated object code: the one-shot `encode()` / `decode()` helpers *and*
  the streaming `serialize` / `decoder()` path (§6.1.1). This is the most common real-world
  use case, so show it explicitly.

### 9.6 `## Memory handling`

Describe **only** ownership and lifetime of the message buffers — who allocates each, who
owns it, how long it must stay alive. Do **not** turn this into an API listing.

* **Output buffer (encoding)** — who owns the buffer written into (**the caller, always**:
  the library never allocates or grows one, §5.1.2) and what happens when it fills (flush
  sink / reuse vs. a buffer-full error). State the port's **`MIN_OUTPUT_BUFFER`** (§5.1.4) here, and that it
  applies to a buffer installed **with a sink**: it is the number a caller needs before it
  can size a streaming buffer. State that a sink is **only ever** handed memory inside the
  installed buffer — pass-through is forbidden (§5.1.6) — so a reader writing a sink knows
  there is no second case to handle.
* **Input buffer (decoding)** — who owns the bytes being parsed and how long they must
  outlive the call. **There is nothing to choose here:** the codec always copies a decoded
  value into storage the caller supplied, on the one-shot path exactly as on the streaming
  one (§6.6). Say who owns the input bytes and until when; do not restate the rule.
* **No views** — say plainly that every decoded value is copied into the caller's
  destination and that nothing the decoder produces aliases the input, on the one-shot path
  as on the streaming one (§6.7). A port has nothing to qualify here; if a README describes
  a borrowed value, either the README or the port is wrong.

State plainly that **no wire value decides an allocation in the codec** (§6.6) — including
that there is no library-owned accumulator for chunk-straddling fields — and where the
storage each decoded field lands in comes from. If the port ships a **static helper layer**
beside the codec (ARCHITECTURE §8), say so and say that it allocates on the generated
layer's behalf, so a reader does not read its buffers as a §6.6 breach (§6.6.1).

Where it helps, add a short owner/lifetime table for the two buffers. Keep the wording
parallel across ports.

### 9.7 `## Build & test`

How to build the library and run the test suite, including the shared vectors from
`assets/`. Keep it brief — the commands and a sentence each.

This is also the README slot §6.2.2's duty refers to: where the port ships a **footprint
profile**, list the build options, the numbers each one chose, and what a conforming peer
may legally send that the build cannot consume. A port that ships no such option writes
nothing here.

### 9.8 `## Benchmarks`

How to run the `perf` and `bench` tools (§10) and **what each measures** (`perf` =
CPU-independent per-op cost; `bench` = throughput in MB/s on the current machine).

Where a single language has **two** corelibs targeting **different use cases** (a general
build vs. a `no_std` / embedded build), add a final subsection that:

* explains the intended use case for each, and
* includes a benchmark comparison table showing why both exist and when to prefer each.

---

## 10. Performance Testing

Every `corelib-*` repo ships **three** benchmark tools, in the language's idiomatic
benchmark folder (`benches/` in Rust, `cmd/perfbench/` in Go, a benchmark module in
Python/Java/C#):

| tool | measures | answers |
|---|---|---|
| **`perf`** | CPU-speed-independent per-op cost — cycles/op via a hardware counter, or instruction count under a profiler | "how good is the implementation?" — machine-neutral |
| **`bench`** | practical throughput on the current machine, in MB/s | "how fast is it here, right now?" |
| **`run_callgrind.sh`** | instructions-per-op (Callgrind `Ir/op`) | the deterministic, machine-independent per-op cost — available on *every* target, with no "cycle counter unavailable" fallback |

**The exact workloads, datasets, timing rules, throughput formula and output grammar are
specified in [`BENCH_SPEC.md`](BENCH_SPEC.md) — the single source of truth.** All three
tools follow it so the numbers are comparable across languages. Do not redefine workloads,
timing or output format here.

---

## 11. Dev Container

Every `corelib-<lang>` repository includes a `.devcontainer/` folder providing a
reproducible development environment based on Docker and VS Code Dev Containers.

### 11.1 Required Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the image: Ubuntu 24.04 base, language toolchain, GitHub CLI (`gh`), Node.js LTS, and Claude Code (`@anthropic-ai/claude-code`). |
| `start.sh` | Starts the container interactively, mounts the workspace and a named `claude-config` volume, loads `.devcontainer/.env` via `--env-file` if present (warns when absent). |
| `devcontainer.json` | References the `Dockerfile`, loads `.devcontainer/.env` via `runArgs`, declares VS Code extensions — language-specific tools **plus** `anthropic.claude-code`. |
| `.env.example` | Committed template listing every supported environment variable (at minimum `GH_TOKEN`). Each variable carries a comment explaining its purpose and required scopes. |

### 11.2 `.env` File (Secrets)

* `.devcontainer/.env` holds actual secrets and is **never committed**.
* It **MUST** appear in `.gitignore` — mandatory in every `corelib-*` repository.
* Developers copy `.env.example` → `.env` and fill in values.
* `start.sh` passes `--env-file "$SCRIPT_DIR/.env"` to `docker run` when the file exists.
* `devcontainer.json` passes `"--env-file", "${localWorkspaceFolder}/.devcontainer/.env"` in
  `runArgs`, so VS Code loads the same variables.

> **Note:** because `runArgs` always includes `--env-file`, the `.env` file **must exist**
> before opening the project as a Dev Container in VS Code. Copy `.env.example` → `.env`
> first — even with all values empty.

### 11.3 VS Code Extensions (`devcontainer.json`)

Declare at minimum:

* **Language extensions** — debugger, formatter/linter, and any test-runner or build-tool
  integration idiomatic for the target language (see `corelib-c-cpp` for a concrete
  example).
* **`anthropic.claude-code`** — required in every port.

---

## 12. GitHub Workflows

Every `corelib-<lang>` repository ships, under `.github/workflows/`:

| workflow | required | section |
|---|---|---|
| **CI** | always | §12.1 |
| **docs** | always | §12.2 |
| **version consistency** | where the tree carries a version to check | §12.3 |

**Filenames are conventional, not normative.** `ci.yml`, `docs.yml` and
`version-consistency.yml` are the family's names, but a repository whose docs workflow is
called `build-doxygen.yaml` is conformant, and `.yml` and `.yaml` are the same file. What
this section fixes is the **trigger, the settings and the ordering** — never the name.

**Two further files are permitted; neither is required:**

* a reusable **`workflow_call`** file, for a build that repeats per target, called from CI;
* a **release** workflow, where the language publishes to a package registry (crates.io,
  PyPI, npm, …). A corelib that ships no package has none, and one that does is not obliged
  to automate the publish here.

**One pipeline per event class.** Everything that runs on a **branch push or a pull
request** belongs to one pipeline: `needs:` cannot cross workflow files, so a target living
in its own file can never be sequenced behind anything. Tag-triggered workflows are outside
this rule — they answer a different event and have nothing to be sequenced behind.

### 12.1 CI — Build & Test (`ci.yml`)

Runs on every push to `main` **and** every pull request targeting `main`.

#### 12.1.1 Matrix build (optional)

A matrix is worthwhile where version differences cause real divergence:

* **scripting / interpreted languages** (Python, Node.js/TypeScript) — standard-library
  behaviour differs between runtime versions, so test current stable and at least one prior
  release;
* **compiler-versioned languages** (C/C++, Rust) — multiple compilers (GCC + Clang, Rust
  stable + beta) surface portability issues.

For a stable, single-vendor toolchain where version differences rarely affect library code
(Go, Java, C#), a single pinned version is acceptable.

**When a matrix is used, set `fail-fast: false`** so a failure on one leg does not cancel
the others — all results must be visible.

* This is also why a matrix **MUST NOT** be folded into a single job that loops over its
  values, however tempting the per-leg setup cost: the loop reports one verdict where the
  matrix reported one per value.
* **Folding an axis into *steps* is allowed**, provided each step carries `if: always()` so
  a failing one cannot hide those after it. That keeps every value's name, duration and log;
  what it gives up is one row per value in the checks list. Use it only for an axis whose
  values **share an environment** — four sets of compile flags, say. An axis needing
  different environments (a runtime version, a cross toolchain) **stays a matrix**.

Use the official setup action for the language (`dtolnay/rust-toolchain`,
`actions/setup-python`, `actions/setup-go`, `actions/setup-java`, `actions/setup-node`) and
enable its built-in dependency cache.

```yaml
strategy:
  fail-fast: false
  matrix:
    version: ["<current-stable>", "<previous-stable>"]
    os: [ubuntu-latest]          # add windows-latest / macos-latest for cross-platform targets
```

#### 12.1.2 Required workflow settings

**A workflow-level `concurrency` group**, so a superseded push releases its runner slots
instead of queueing behind itself:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
```

* `cancel-in-progress` is deliberately **off on `main`**: a push there must keep its full
  run, including the coverage and badge jobs that only run on `main`. **This is the one
  setting here with no per-repository judgement in it** — a repository that cancels on
  `main` loses a badge update whenever two pushes land close together.
* A reusable `workflow_call` file declares **no group of its own**. It runs inside the
  calling workflow's run and is already covered by the caller's group; a second group would
  only contend with the first for the same run.

**`timeout-minutes` on every job that runs steps.** GitHub's default is 360 minutes, and a
wedged job holds a runner slot for all of them. Not hypothetical: an `apt-get install` in
this family has run for **87 minutes** and twice never returned.

* Pick roughly **four times** the job's normal duration.
* **Wrap any network fetch the workflow issues itself** — `apt-get`, `curl`, `wget` — in a
  bounded retry. Do **not** wrap the `setup-*` actions or the language's package manager;
  they retry and cache on their own.
* **A job that only delegates with `uses:` is exempt**, mechanically: it cannot carry
  `timeout-minutes` at all. The bound belongs on the jobs of the called workflow, where the
  steps are.

#### 12.1.3 Required steps

1. `actions/checkout@v4`
2. Set up the runtime from `matrix.version`, caching enabled.
3. Install / restore dependencies.
4. Build in **both** debug and release configurations.
5. Run the full test suite, including the shared vectors from `assets/` (§7).
6. Generate a coverage report with the language's idiomatic tool (`cargo llvm-cov`,
   `coverage.py`/`pytest-cov`, `gcov`/`gcovr`, `go test -cover`, JaCoCo, Coverlet).
7. Upload it to a coverage service (Codecov or equivalent) and wire the badge into the
   README (§9.2).

#### 12.1.4 Ordering: gate the fan-out

Steps 1–3 are cheap and every leg repeats them. Where a repository fans out wide, a **gate
job runs first** and everything else declares `needs:` on it, so a broken tree is discovered
once rather than once per leg. In a repository with many targets this is the difference
between **51 runner-minutes and 28 seconds** to learn the same fact.

**Both halves of the gate are conditional, and a repository that warrants neither is
conformant with no gate at all:**

| half | applies only where |
|---|---|
| **lint gate** | the language already has a linter configured in the tree. Introducing one to satisfy this section is not the point: a corelib whose build is `mvn -B verify` or `dotnet test`, with no linter beside it, has nothing to gate on. |
| **compile-only gate** | the fan-out is large enough to pay for the serialised minute — roughly a factor of four between what the fan-out costs and what the gate costs. A matrix of three runtime versions or four compile configurations sits below that line. |

**The gate compiles and does not test** — a gate that runs the suite is a second pipeline,
not a gate. Where the linter already compiles (`cargo clippy --all-targets`), the lint job
*is* the gate, and a separate build job only compiles the same tree twice.

### 12.2 Docs — API Documentation (`docs.yml`)

Runs on push to `main` only, **not** on pull requests.

| Language | Tool |
|---|---|
| C / C++ | Doxygen |
| Rust | `cargo doc` |
| Python | Sphinx (`sphinx-apidoc` + HTML builder) |
| TypeScript | TypeDoc |
| Go | `pkgsite` / `godoc -http` static export |
| Java | Javadoc (`mvn javadoc:javadoc` or `gradle javadoc`) |
| C# | DocFX |

**GitHub Pages deployment — Actions-based, no `gh-pages` branch.** The repository's Pages
setting (Settings → Pages → Build and deployment → Source) **MUST** be
**"GitHub Actions"**.

```yaml
permissions:
  pages: write
  id-token: write
```

**Required steps**

1. `actions/checkout@v4`
2. Set up the runtime, pinned to current stable (no matrix needed).
3. Install dependencies.
4. Generate HTML documentation into a local folder (`docs/html/`, `target/doc/`, `site/`).
5. Upload it as a Pages artifact:
   ```yaml
   - uses: actions/upload-pages-artifact@v3
     with:
       path: <html-output-folder>
   ```
6. Deploy:
   ```yaml
   - uses: actions/deploy-pages@v4
   ```

**Published URL:** `https://sofa-buffers.github.io/<repo>/` — the target of the **Docs
badge** (§9.2).

**Why this stays its own file.** The docs workflow owns a workflow-level `concurrency` group
so two Pages deployments can never race. A workflow may hold only one such group and CI
needs its own for cancel-on-superseded (§12.1.2), so the two cannot share a file. Keeping
them apart also keeps `pages: write` and `id-token: write` out of the workflow that builds
and tests — scope them to the deploy job alone.

### 12.3 Version consistency (`version-consistency.yml`)

Runs on **tag pushes only**:

```yaml
on:
  push:
    tags: [ 'v*' ]
```

It compares the tag, minus the leading `v`, against the version in every manifest the
repository ships — `Cargo.toml`, `package.json`, `pubspec.yaml`, `pom.xml`, the `.csproj`,
`build.zig.zon`, `conanfile.py`, `library.json`, the CMake `project()` version,
`__version__` — and fails the tag on any mismatch.

**The trigger is not a detail.** A comparison is only meaningful when there is a tag to
compare against, and between releases a manifest may legitimately run ahead of the newest
tag: a repository preparing 0.11.0 while `v0.10.0` is newest is correct, not broken. Running
the check on `main` or on pull requests compares the manifests against whatever tag happens
to be newest, which says nothing about the commit under test.

**Two cases have nothing to check and MUST NOT carry this workflow:**

* **Go** — the module version *is* the tag and appears nowhere in the tree;
* any corelib that **has not yet cut its first release**.

The rule generalises past Go: wherever the tag is the single source of truth for the
version, there is no second copy to disagree with it.

---

## 13. Conformance Checklist

A new `corelib-<lang>` is conformant when:

**Identity and API surface**

- [ ] All public symbols live under the `sofab` namespace; the registry package name is
      derived in the registry's own convention from `sofa-buffers` + `corelib`, plus a
      variant suffix where the language ships more than one corelib (§6).
- [ ] API version constant/getter returns `1` (§6.2).
- [ ] The generated-object surface uses only the closed name set of §6.1.1, and the
      streaming primitives suffice to build a thin generated layer whose one-shot
      `encode()`/`decode()` are wrappers over the streaming path (§6.1).

**Wire format**

- [ ] Varint and zig-zag encode/decode match §4.1–4.2 exactly, including minimal-form
      encode, non-minimal-tolerant decode, and the 10-byte / 64-bit bound (§4.1.2–4.1.3).
- [ ] No part of an incomplete varint is evaluated — a settled low-3-bit sub-field never
      influences an outcome (§4.1.1).
- [ ] Field header packing `(id << 3) | type` and all 8 wire types (§4.3).
- [ ] Fixlen word `(length << 3) | fixlen_type`, LE floats, UTF-8 strings without
      terminator, blobs (§4.6).
- [ ] Integer arrays, and fixlen arrays with a single shared fixlen word; no dynamic
      subtypes in fixlen arrays; the §4.8.1 decode order (§4.7–4.8).
- [ ] Sequence start/end framing, fresh ID scope, single-byte `0x07` end, id discarded but
      still bounded by `ID_MAX`, skip-by-walking with depth tracking, rejection past
      `MAX_DEPTH` = 255 (§4.9).
- [ ] **Every §6.2.2 variation the port ships — selectable or built in — passes the gate**
      (it buys footprint, it emits nothing outside §4) **and is stated in the README's build
      section** (§9.7), with the numbers it chose and what a conforming peer may send that
      the build cannot consume. A port that departs from the full profile in no way at all
      takes this item trivially.

**Encoding**

- [ ] The encoder can produce the canonical sequence encoding of MESSAGE_SPEC §2 in a
      **single forward pass** — an all-default `struct`/`union` field omitted, an
      all-default wrapper-array element still framed — either through a descriptor/object
      layer that decides per field before opening, or through the `begin_lazy` / `end` /
      `end_keep` API (§6.0.1). Held-back headers never make the bytes depend on the
      output-buffer size.
- [ ] **Streaming encode** into a smaller-than-message buffer via flush callback / sink,
      with mid-stream buffer swap, over a **caller-supplied** buffer with a start offset —
      the corelib allocates no output buffer at all; the generated layer does and hands one
      in like any other caller (§5.1).
- [ ] **`MIN_OUTPUT_BUFFER` declared** (§5.1.4), at most 20, stated in the README's memory
      section (§9.6), enforced on every buffer installed **with a sink** and on no other,
      and used as the size in the §7.2 item 4 encode test.
- [ ] The returning-flush-callback contract holds both ways: returning without installing
      resumes at offset 0, a taking sink installs a replacement before returning (§5.1.5).
- [ ] **No pass-through** — a sink is only ever handed memory inside the installed buffer,
      on every flush of every message; there is no permission that reinstates it (§5.1.6).
      Tested by §7.2 item 4.

**Decoding**

- [ ] **Streaming decode** via `feed` of arbitrarily small chunks, push-callback /
      pull-read, lazy field binding and auto-skip, returning `COMPLETE` / `INCOMPLETE` /
      `INVALID` with **no** `finish`/`finalize` step — `INCOMPLETE` surfaced, never
      auto-promoted to an error (§5.2).
- [ ] `INVALID` wins over `INCOMPLETE`, and every construct is validated where its
      describing bytes are read — before the payload they describe is consumed or awaited
      (§5.2.3).
- [ ] **Chunk lifetime** honoured: a fed chunk is borrowed only for the duration of `feed`
      (§6.0).
- [ ] **The visitor is the only decode surface** — every port exposes it (in a language
      without objects, as callbacks with a context pointer), and **no port offers a second
      one**: no pull-parser, iterator, cursor, or convenience wrapper that decodes by another
      route. No exemption for constrained targets (§5.3.1).

**Memory**

- [ ] **The codec is heap-free (§6.6)** — no `malloc`/`realloc`/`free`, no `new`/`delete`,
      no allocator call, no growable container of its own, and no growing of a destination
      the caller supplied — on either side, on any path, in any build configuration.
      Verified **both ways** (§6.6.4): no allocation primitive is reachable from a codec
      entry point, **and** an allocation count or heap high-water mark over a complete
      encode and a complete decode is **zero** — apart from the language-forced handles of
      §6.6.2, which are itemised in the README and pinned by a test. Fixed-size working
      state bounded by this document's constants is not allocation. Applies to the
      **codec**; the static helper layer beside it (ARCHITECTURE §8) is the generated
      layer's and may allocate — but only where no codec path calls into it (§6.6.1).
- [ ] **Receiver-side limits present and finite** — `max_dyn_array_count`,
      `max_dyn_string_len`, `max_dyn_blob_len`, with no unset or unlimited state, supplied
      by generated code, enforced at the count/length header (for a sequence array, at the
      element index) before any allocation, and **rejected, never clamped** (§6.2.1).
- [ ] **No views (§6.7)** — the codec exposes no zero-copy view, no payload-position
      getter and no borrowed value, on the one-shot path as on the streaming one. Every
      decoded value is copied into the caller's destination. Proven by scrubbing the
      one-shot buffer after `decode` returns (§7.2 item 4).
- [ ] **Exactly two per-field intents** — `read` and `skip`, never a third. There is no
      `examine`, because with views gone a wanted field is always read and therefore always
      validated (§6.7.2).

**Errors, strings, floats**

- [ ] Result/error reporting follows the §6.3 baseline codes — idiomatic exceptions where
      the language uses them by default, return codes / result objects otherwise. A
      type-mismatched read is a skip, not an error. `LimitExceeded` is kept distinguishable
      from `InvalidMessage` (§6.3).
- [ ] The three refusal tiers of §6.3 are told apart on **every** aggregate surface —
      schema bound → `InvalidMessage`, receiver cap → `LimitExceeded`, **destination too
      short → `InvalidArgument`** — with `string`, `blob` and array agreeing, and a
      language-specific range error refining `InvalidArgument` rather than replacing it.
- [ ] UTF-8 string-validity contract per §6.4 — byte-container targets expose
      `SOFAB_STRICT_UTF8` (ON by default; constrained profiles may default OFF or compile it
      out), Unicode-string targets are always strict (option omittable), symmetric
      (`INVALID` on decode, `InvalidArgument` on encode), OFF pinned to raw-or-reject (never
      silent `U+FFFD`/lossy), skipped fields never validated, `utf8_valid` exposed where
      codegen materializes byte-container strings, chunk boundaries never change the
      outcome, and conformance tests run with the check ON.
- [ ] **`fp32` bit-exactness (§6.5)** — a signaling, quiet and negative `fp32` NaN each
      round-trips bit-for-bit at a scalar **and** an array position, on **every** decode
      surface. Native-`fp32` targets get this for free; double-only targets provide the raw
      wire-bytes path and never re-encode from the widened value.

**Testing and repository**

- [ ] All shared **test vectors** pass for encode and decode, plus chunked, roundtrip,
      malformed, tolerance, truncation and skip tests (§7.2 items 1–7).
- [ ] The `sequence_growth` cases pass, asserting container length and outcome per case —
      index bound, gap fill, no partial extension after a rejected id (§7.2 item 8). Growth
      geometry tested where the language can count allocations, documented as untested where
      it cannot; a port that never grows is excluded by `requires` and says so.
- [ ] Coverage >90%, wired into CI with a README badge (§7.3).
- [ ] `assets/` populated per §8 — branding from `documentation`, `test_vectors.json` from
      `corelib-c-cpp`.
- [ ] README follows the family format with badges and the required sections (§9).
- [ ] README carries facts, not justification: no rationale outside the §9.3 table, no
      anticipated objections, no restatement of the specs. A section beyond the §9 shape is
      fine where the port has something of its own to state — feature flags, packaging,
      targets — provided it states facts (§9.0.1–9.0.2).
- [ ] `perf` (CPU-independent), `bench` (MB/s) and `run_callgrind.sh` (Callgrind `Ir/op`)
      present and runnable (§10).
- [ ] `.devcontainer/` present with `Dockerfile`, `start.sh`, `devcontainer.json` and
      `.env.example`; `devcontainer.json` lists language-appropriate extensions and
      `anthropic.claude-code`; `.devcontainer/.env` is gitignored (§11).

**CI**

- [ ] CI builds and tests on push and PR; a matrix is used where version differences matter;
      coverage uploaded and the badge wired into the README (§12.1).
- [ ] Every workflow file triggered by an event declares a `concurrency` group, with
      `cancel-in-progress` off on `main`; a reusable `workflow_call` file declares none and
      is covered by its caller's (§12.1.2).
- [ ] Every job that runs steps declares `timeout-minutes`, and every network fetch the
      workflow issues itself is wrapped in a bounded retry (§12.1.2).
- [ ] Everything that runs on a branch push or a pull request lives in one pipeline, so a
      gate can precede the fan-out where one is warranted — a lint gate where a linter is
      configured, a compile-only gate where the fan-out is large enough to pay for it. A
      repository with neither is conformant with no gate (§12.1.4).
- [ ] The version-consistency workflow triggers on tag pushes only and compares the tag
      against every manifest the repository ships — or is deliberately absent because the tag
      is the only version there is (§12.3).
- [ ] The docs workflow generates HTML docs and publishes to GitHub Pages via the
      Actions-based deployment (no `gh-pages` branch); the Docs badge links to the published
      site (§12.2).

---

*This document is part of the SofaBuffers `documentation` repository and is the
language-independent specification of the format. The shared `test_vectors.json` is
authoritative for any detail not fully captured here.*
