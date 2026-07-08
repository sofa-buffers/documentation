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

Two messages plus one array workload. The exact bytes must match, so use the
literal values below (do **not** substitute language math constants like `PI`/`E`
— that changes the encoded bytes and breaks comparison).

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
rows `^(encode|decode):\s+(u64 array \(1000\)|typical message)\s+([\d.]+)$`,
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
decode: u64 array (1000)         <v>
decode: typical message          <v>

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
decode: u64 array (1000)             <n>         <bytes>
decode: typical message              <n>         <bytes>
```

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
