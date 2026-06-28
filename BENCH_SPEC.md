# SofaBuffers benchmark specification

This is the single source of truth for the cross-language benchmark suite. Every
`corelib-*` implementation ships a **throughput** (`bench`) and a **per-op**
(`perf`) tool that run the *same workloads, on the same data, measured the same
way, and print the same format*. Numbers are therefore directly comparable across
languages. A central harness builds each implementation in its own
`.devcontainer` and parses the output below.

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

## Reference implementation

`corelib-rs/benches/bench.rs` and `corelib-rs/benches/perf.rs` are the textual
golden reference for the format above; the C/C++ tools under
`corelib-c-cpp/bench/` mirror them. New or changed implementations should produce
byte-identical structure (only the `<Label>` and the numbers differ).

## Supplementary, language-native views (not part of the comparison tables)

These are allowed *in addition to* the standard tools, but are not parsed into the
cross-language tables:

- **Callgrind `Ir/op`** (instructions per op) — deterministic, machine-independent
  cost, via each repo's `bench/run_callgrind.sh`.
- **Go `go test -bench`** — native `ns/op` + `allocs/op` (incl. zero-copy
  variants), reported separately.
