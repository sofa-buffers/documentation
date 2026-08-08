# SofaBuffers benchmark specification

This is the single source of truth for the cross-language benchmark suite. Every
`corelib-*` implementation ships three tools that run the *same workloads, on the
same data, measured the same way, and print the same format*:

- **throughput** (`bench`) — MB/s over a CPU-time loop;
- **per-op** (`perf`) — cycles/op + MB/s;
- **instruction cost** (Callgrind `Ir/op`) — instructions retired per op,
  **deterministic and machine-independent** (see "Instruction cost" below).

Numbers are therefore directly comparable across languages. A central harness
builds each implementation in its own `.devcontainer` and parses the output
below. All three tools are required: an implementation that ships only two is
incomplete.

> If you change a benchmark, change it here first. Output that doesn't match this
> grammar will not be parsed into the comparison tables.

## Datasets (identical field ids, types and values in every language)

Three messages, one array workload and one streaming workload. The exact bytes must
match, so use the literal values below (do **not** substitute language math
constants like `PI`/`E` — that changes the encoded bytes and breaks comparison).

### `u64 array (1000)`
1000 `u64` values: `src[i] = i * 0x9E3779B97F4A7C15` (wrapping `u64` multiply).

### `typical` message (used by `bench`)
Seven fields, ids 1..7 (encodes to ~37 bytes):

| id | type | value |
|----|------|-------|
| 1 | unsigned | `0xDEADBEEF` |
| 2 | signed | `-12345` |
| 3 | bool | `true` |
| 4 | fp32 | `3.14159` |
| 5 | string | `"sofab"` |
| 6 | unsigned array (u16) | `[10, 20, 30, 40]` |
| 7 | sequence | `{ unsigned 1 = 99; signed 2 = -7 }` |

### `perf` message (used by `perf`)
Twelve fields, ids 1..12 (encodes to **170 bytes**):

| id | type | value |
|----|------|-------|
| 1 | unsigned | `0xDEADBEEF` |
| 2 | signed | `-12345` |
| 3 | unsigned | `0x0123456789ABCDEF` |
| 4 | signed | `-5000000000000` |
| 5 | bool | `true` |
| 6 | fp32 | `3.14159` |
| 7 | fp64 | `2.718281828459045` |
| 8 | string | `"perf-benchmark-message"` |
| 9 | unsigned array (u32) | `[1000000, 2000000, …, 8000000]` (1e6·1..8) |
| 10 | signed array (i32) | `[-100000, -200000, …, -800000]` (-1e5·1..8) |
| 11 | fp64 array | `[3.14159265, 6.28318530, 9.42477795, 12.56637060]` |
| 12 | sequence | `{ unsigned 1 = 99; signed 2 = -7 }` |

The encoded size of the `perf` message (170 bytes on every implementation) is a
quick parity check: if your `perf` prints a different `message size`, your
encoding diverges.

### `blob 1MB` message (used by `bench`)

One field, id 1, type `blob`, **declared without `maxlen`** — the unbounded
declaration is the point, not incidental: it is what makes the message larger than
any buffer a caller can pre-size from the schema. Payload is exactly **1,000,000
bytes**, so `MB/s` reads directly against the `MB = 1e6` convention:

```
b[i] = (i * 0x9E3779B97F4A7C15) & 0xFF      // wrapping u64 multiply, low byte
```

Same constant as `u64 array (1000)`, so there is one magic number in this file
rather than two and the derivation is identical in every language.

`blob` rather than `string` on purpose: a megabyte of UTF-8 would put the §6.4
validator in the measurement and dominate it. This workload measures buffer
handling. (A large-`string` workload for measuring the validator would be a
reasonable separate addition — different question, different dataset.)

Encoded size is **1,000,005 bytes** on every implementation — a 1-byte header
(`(1 << 3) | 2`), a 4-byte `fixlen_word` (`(1000000 << 3) | 3`), and the payload.
Like the `perf` message's 170, it is a parity check.

**Three required rows, and the interesting number is the gap between the first two:**

| row | how it is driven |
|-----|------------------|
| `encode: blob 1MB one-shot` | caller buffer of **1,000,005** bytes, **no sink** |
| `encode: blob 1MB streaming` | caller buffer of exactly **4096** bytes with a flush sink, pass-through **not granted** |
| `decode: blob 1MB` | fed in **4096**-byte chunks |

The one-shot row is the floor — one contiguous write, no flush logic. The streaming
row is the same bytes through ~245 flushes. Their difference is the cost of the
divisible-run path (CORELIB_PLAN §5.1), per port, and it is the only place in this
suite where that path is exercised at all: the other three workloads are
schema-bounded and small enough that no flush occurs mid-encode.

A fixed 4096 rather than each port's own buffer size, so the rows stay comparable
across languages. `MIN_OUTPUT_BUFFER` does not enter into it — it is at most 20, so
4096 always satisfies it, and whether the declared minimum *works* is a conformance
question settled by CORELIB_PLAN §7.2 item 4, not a throughput one.

The one-shot buffer is sized **by hand**, not from the generated `MAX_SIZE`. This
schema is unbounded, so its `MAX_SIZE` is the configured ceiling (4096 by default)
rather than a size the message cannot exceed — the bench drives the corelib
directly and states the number outright.

**Pass-through is not granted for the required streaming row.** Since CORELIB_PLAN
§5.1 lets a caller permit a `string`/`blob` run to reach the sink without passing
through the buffer, leaving the permission unstated would have two ports print the
same row for entirely different work — one copying a megabyte in 4096-byte pieces,
the other handing it over in one call. The required row therefore measures the copy
path on every port.

A port that **implements** pass-through **SHOULD** additionally print:

```
encode: blob 1MB passthrough     <v>
```

driven identically to the streaming row but with the permission granted. Its gap to
the streaming row is what pass-through is worth on that port. The row is **optional**
— a port that does not implement pass-through omits it entirely rather than printing
a placeholder, and the harness treats it as absent-or-present per port.

**The streaming sink consumes and discards.** It **MUST NOT** accumulate the bytes,
and **MUST NOT** write to a socket or file. Both would measure something other than
the encoder: an accumulator adds to the streaming row a copy the one-shot row never
pays, and I/O is not deterministic under Callgrind. Do the minimum the language
needs to keep the call from being optimised away — accumulating an XOR of one byte
per call, say — and nothing more.

**Read these rows against each other, not against the other workloads.** Five bytes
of this message are metadata and a million are payload, so the throughput figure is
the platform's `memcpy` and the machine's memory bandwidth — it is not a statement
about the corelib and does not belong next to `typical message` in a "how fast is
this port" reading. The signal lives in the **differences**: one-shot to streaming
is the flush machinery, streaming to pass-through is what the §5.1 permission buys.
Under `MB/s` the first of those is a low-single-digit fraction of a bandwidth-bound
row and will not survive the noise; under Callgrind `Ir/op` it is a clean double-digit
fraction, because instruction counts do not care about bandwidth. **`Ir/op` is the
number to read for this workload.**

### `composite` message (used by `bench`)

The three datasets above are flat: every field is present, every array is a compact
scalar array, the one sequence is a single level deep, and every id fits a one-byte
header. Several encoder paths therefore never run at all — and they are not obscure
ones.

This message exercises them. Field ids and values:

| id | type | value |
|----|------|-------|
| 1 | **string array** (wrapper form, §5.1) | 64 elements, element *i* = `"item-"` + *i* in decimal, no padding (`item-0` … `item-63`) |
| 2 | string | `"aä€𝄞"` repeated **32** times — 320 UTF-8 bytes covering 1-, 2-, 3- and 4-byte sequences |
| 3 | sequence | `{ 1: sequence { 1: sequence { 1: unsigned 7 } }, 2: signed -1 }` |
| 4 | struct | **equal to its declared default**, so the encoder omits it (§2) |
| 130 | unsigned | `0xDEADBEEF` |

What each one is there for:

* **Field 1** is the only wrapper array in the suite — the form that carries a
  header *per element* (§5.1). Its 64 elements also straddle the one-byte header
  boundary on their own: element ids 0–15 encode as one byte, 16–63 as two.
* **Field 2** puts the §6.4 UTF-8 validator on a payload that is not ASCII. The
  4-byte sequence matters on its own: it is a surrogate pair in every UTF-16 port.
* **Field 3** is nesting at depth 3, so the lazy hold-back run (§6) grows past the
  single level `typical` and `perf` reach.
* **Field 4** is the only field in the suite the encoder is required to **not**
  write. Without it the ≠-default test never takes its omit branch, and neither does
  the hold-back's discard path.
* **Field 130** is the only two-byte field header in the suite: `(130 << 3) | 0`.

The exact encoded size is the parity check, as with `perf`'s 170; take it from the
reference implementation (§ *Reference implementation* below) once the workload
lands there, and it must then match on every port.

**Three rows, one of which is the point:**

| row | how it is driven |
|-----|------------------|
| `encode: composite` | buffer sized to hold the message, no sink |
| `decode: composite` | whole message, all fields read |
| `decode: composite skip-all` | same bytes, **every** field and sub-sequence skipped |

The skip row measures the path a router or filter runs in production — walk the
message, materialize nothing — and §7.2 item 7 requires it be *tested* while nothing
so far measured it. Its distance from `decode: composite` is what not-decoding is
worth.

## Timing

- Measure over a **~1 s process/thread CPU-time loop**, never wall-clock. Use the
  highest-resolution process CPU clock the platform offers
  (`clock_gettime(CLOCK_PROCESS_CPUTIME_ID)`, `clock()`, `getrusage(RUSAGE_SELF)`,
  `process.cpuUsage()`, `Process.TotalProcessorTime`, `getCurrentThreadCpuTime`,
  `time.process_time()`, …).
- Do one warmup call (or ~1000 for per-op) before starting the timer.
- `MB = 1e6 bytes`; `throughput MB/s = message_bytes * iterations / cpu_seconds / 1e6`.
- `cycles/op` uses a hardware cycle counter (x86 `rdtsc`, AArch64 `cntvct_el0`)
  where available; otherwise print the "unavailable" line (see below). Managed and
  scripting runtimes (JVM, .NET, JS, CPython, Go) report CPU time/op only.

## Output grammar

The harness matches these with the regexes
`=== SofaBuffers (.+?) throughput` / `=== SofaBuffers (.+?) per-op`, throughput
rows `^(encode|decode):\s+(u64 array \(1000\)|typical message|blob 1MB one-shot|blob 1MB streaming|blob 1MB passthrough|blob 1MB|composite skip-all|composite)\s+([\d.]+)$`,
(the `passthrough` row is optional — see the dataset above — so the harness must
tolerate its absence rather than treat a missing row as a parse failure),
per-op markers containing `perf: serialize`/`perf: deserialize`, and value lines
`cycles/op : <n>` / `CPU time/op : <n> ns`. The captured `<Label>` (e.g. `Rust`,
`C++`, `Go`) selects the display name, so keep it short and stable.

### Throughput (`bench`)
```
=== SofaBuffers <Label> throughput (CPU time, MB/s) ===
Workload                           MB/s
--------                           ----
encode: u64 array (1000)         <v>
encode: typical message          <v>
encode: blob 1MB one-shot        <v>
encode: blob 1MB streaming       <v>
encode: blob 1MB passthrough     <v>
encode: composite                <v>
decode: u64 array (1000)         <v>
decode: typical message          <v>
decode: blob 1MB                 <v>
decode: composite                <v>
decode: composite skip-all       <v>

MB = 1e6 bytes. ~1s CPU-time loop per workload.
```
Rows use a label left-justified to 26 chars and the value right-justified to 12
chars with 2 decimals. The `blob 1MB passthrough` row is the one optional line: a
port that does not implement pass-through omits it, and prints no placeholder in
its place.

### Per-op (`perf`)
```
=== SofaBuffers <Label> per-op cost (cycles/op + throughput MB/s) ===

--- perf: serialize (stream API) ---
  iterations    : <n>
  message size  : <bytes> bytes
  cycles/op     : <n>  (hardware cycle counter)
  CPU time/op   : <n> ns  (process CPU time, not wall-clock)
  throughput    : <n> MB/s  (speedtest, MB = 1e6 bytes)

--- perf: deserialize (stream API) ---
  ...same five lines...

cycles/op tracks code cost; MB/s is this machine's throughput.
```
When no hardware cycle counter is available, replace the `cycles/op` value with a
parenthetical, e.g. `cycles/op     : (cycle counter unavailable on CPython)`.
Keep the trailing `cycles/op tracks code cost; …` line on every implementation
for consistency.

### Instruction cost (Callgrind `Ir/op`)

A `run_callgrind.sh` in each repo (`bench/run_callgrind.sh`; `benches/` in the
Rust ports) reports **instructions retired per op (Ir/op)** under Callgrind.
Unlike wall-clock or cycle counts, an instruction count is deterministic and
independent of the host's clock speed and scheduler, so the numbers compare
across machines — and, unlike `perf`'s cycles/op, they are available on *every*
target (there is no "counter unavailable" fallback). This is the signal a CI
performance-regression gate should use.

The tool prints exactly this table (only the numbers differ per language):

```
===============================================================================
 SofaBuffers <Lang> instruction cost   (Callgrind, Ir/op)
 instructions/op: lower is better. Deterministic & machine-independent.
===============================================================================
Workload                           instr/op     bytes
--------                           --------     -----
encode: u64 array (1000)             <n>         <bytes>
encode: typical message              <n>         <bytes>
encode: blob 1MB one-shot            <n>         1000005
encode: blob 1MB streaming           <n>         1000005
encode: blob 1MB passthrough         <n>         1000005   (optional)
encode: composite                    <n>         <bytes>
decode: u64 array (1000)             <n>         <bytes>
decode: typical message              <n>         <bytes>
decode: blob 1MB                     <n>         1000005
decode: composite                    <n>         <bytes>
decode: composite skip-all           <n>         <bytes>
```

The `blob 1MB` rows are where the instruction count earns its keep: the delta
between one-shot and streaming is the divisible-run cost with the host's memory
subsystem and scheduler taken out of it, and — where the optional third row is
present — the gap from streaming to pass-through is what CORELIB_PLAN §5.1's
permission buys, measured the same deterministic way. Ports using **two-rep subtraction** should
keep the rep counts small for this workload (`R1 = 1`, `R2 = 3` is enough) — a
megabyte of copying per op under Callgrind is slow, and the subtraction cancels
fixed cost just as well at three reps as at three hundred.

The `bytes` column is the encoded message size and must match `perf`'s. Two
measurement mechanisms are permitted, both yielding one op's Ir:

- **Native symbol toggle** (compiled ports: C/C++, Rust, Zig, Go) — the bench
  binary exposes each workload as a non-inlined `run_<workload>` symbol doing
  exactly one op, and the script runs it under
  `valgrind --tool=callgrind --collect-atstart=no --toggle-collect=run_<workload>`.
- **Two-rep subtraction** (JIT/interpreted ports: Python, TypeScript, C#, Java)
  — no stable native symbol exists, so each workload is run at two rep counts
  `R1`, `R2` and the totals are subtracted: `Ir/op = (Ir(R2) − Ir(R1))/(R2 − R1)`,
  which cancels startup, JIT/compile and setup cost. The two runs must differ
  *only* in the measured rep count; managed runtimes should pin the JIT tier and
  disable GC so the fixed cost is stable enough that the residual jitter is a
  negligible fraction of the reported per-op number.

## Reference implementation

`corelib-rs/benches/bench.rs` and `corelib-rs/benches/perf.rs` are the textual
golden reference for the `bench`/`perf` format above; the C/C++ tools under
`corelib-c-cpp/bench/` mirror them, and `corelib-c-cpp/bench/run_callgrind.sh`
(native toggle) plus `corelib-ts/bench/run_callgrind.sh` (two-rep subtraction)
are the golden references for the instruction-cost tool. New or changed
implementations should produce byte-identical structure (only the `<Label>`/
`<Lang>` and the numbers differ).

## Supplementary, language-native views (not part of the comparison tables)

These are allowed *in addition to* the standard tools, but are not parsed into the
cross-language tables:

- **Go `go test -bench`** — native `ns/op` + `allocs/op` (incl. zero-copy
  variants), reported separately.
