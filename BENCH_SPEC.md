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

Two messages, one array workload and one streaming workload. The exact bytes must
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

**Three rows, and the interesting number is the gap between the first two:**

| row | how it is driven |
|-----|------------------|
| `encode: blob 1MB one-shot` | buffer sized to hold the whole message, **no sink** |
| `encode: blob 1MB streaming` | caller buffer of exactly **4096** bytes with a flush sink |
| `decode: blob 1MB` | fed in **4096**-byte chunks |

The one-shot row is the floor — one contiguous write, no flush logic. The streaming
row is the same bytes through ~245 flushes. Their difference is the cost of the
divisible-run path (§5.1), per port, and it is the only place in this suite where
that path is exercised at all: the other three workloads are schema-bounded and
small enough that no flush occurs mid-encode.

A fixed 4096 rather than each port's own buffer size, so the rows stay comparable
across languages.

**The streaming sink consumes and discards.** It **MUST NOT** accumulate the bytes,
and **MUST NOT** write to a socket or file. Both would measure something other than
the encoder: an accumulator adds to the streaming row a copy the one-shot row never
pays, and I/O is not deterministic under Callgrind. Do the minimum the language
needs to keep the call from being optimised away — accumulating an XOR of one byte
per call, say — and nothing more.

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
rows `^(encode|decode):\s+(u64 array \(1000\)|typical message|blob 1MB one-shot|blob 1MB streaming|blob 1MB)\s+([\d.]+)$`,
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
decode: u64 array (1000)         <v>
decode: typical message          <v>
decode: blob 1MB                 <v>

MB = 1e6 bytes. ~1s CPU-time loop per workload.
```
Rows use a label left-justified to 26 chars and the value right-justified to 12
chars with 2 decimals.

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
decode: u64 array (1000)             <n>         <bytes>
decode: typical message              <n>         <bytes>
decode: blob 1MB                     <n>         1000005
```

The `blob 1MB` rows are where the instruction count earns its keep: the delta
between one-shot and streaming is the divisible-run cost with the host's memory
subsystem and scheduler taken out of it. Ports using **two-rep subtraction** should
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
