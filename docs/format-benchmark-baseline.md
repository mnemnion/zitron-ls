# Formatter benchmark baseline

Captured 2026-09-12 against formatter HEAD `639fe86847dee636e04ed59f489d2af25304406a`, with only the benchmark harness and build target added. Tree-sitter Zitron dependency HEAD: `7f2726a69f1365c512e44e4c69ceeafc40083819` (clean). Zig 0.16.0, `ReleaseFast`, aarch64 macOS 15.7.7 (24G720). These measurements are from the local development machine; other agents avoided compilation and timing work during the measurement window. They are not isolated-machine confidence intervals.

```sh
zig build bench-format -Doptimize=ReleaseFast -- 11
# Optional substring filter:
zig build bench-format -Doptimize=ReleaseFast -- 11 drops
zig build bench-format -Doptimize=ReleaseFast -- 11 formatted
zig build bench-format -Doptimize=ReleaseFast -- 1 worker
```

The default is 11 repetitions. The second argument filters case names. The build target sets the working directory to the repository root, so fixture paths are reproducible. It compiles the same formatter and embedded-Zig sources directly, allowing the independent worker retention probe without changing production visibility.

## Measurement boundary

Each fixture is parsed once before measurement. Each mode performs two unmeasured warmups, then times `formatter.format` only using `std.Io.Clock.awake`. Timing includes internal queue initialization, the embedded Zig worker, both internal arena lifetimes, layout, rendering, and the final caller-owned copy. Input generation, tree-sitter parsing, output verification, freeing the returned output, and caller arena reset are excluded. Timed calls use uninstrumented allocators; a separate single untimed call collects allocation counters.

`direct_smp` passes `std.heap.smp_allocator` directly. `warm_caller_arena` passes a caller-owned arena backed by that allocator and resets it with `.retain_capacity` after each call. It tests reusing the **caller arena only**. Both modes still construct and destroy the formatter's document arena and worker arena on every call. Neither mode measures cold CPU caches or process startup. This benchmark does not add any direct use of `page_allocator`.

The counters intercept the allocator passed to `format`. `allocs` counts successful allocation calls; resize/remap columns count attempts, including failures. `granted_bytes` sums successful allocations and positive size increments. `peak_live_bytes` tracks requested bytes still logically owned through that interface, including the returned output before it is freed. These are **logical caller-boundary bytes**, not RSS or total formatter allocations. Arena suballocations, worker arena allocations, tree-sitter allocations, and I/O runtime allocations do not pass through this counter. A caller arena can ignore individual frees, so the counter does not measure its physical retained capacity. Allocation counts and resize success can vary with backing allocator state.

Every fixture must parse without tree-sitter errors. Every timed output must match a separately formatted reference byte-for-byte. The CSV includes output length and Wyhash, enabling comparisons after changes. Successful output checks are deterministic for this executable; timing percentiles are descriptive order statistics (median index `n/2`, p90 index `floor(0.9n)`). No end-to-end LSP diff, JSON encoding, or response transmission is measured.

Raw formatting results: [format-benchmark-baseline.csv](format-benchmark-baseline.csv). Independent worker retention results: [format-benchmark-worker-baseline.csv](format-benchmark-worker-baseline.csv). The original cases were captured in one run; the already-formatted samples were added in a filtered follow-up run with the same formatter sources.

## Representative results

Direct SMP results; milliseconds and decimal MB:

| Case | Input bytes | Median ms | p90 ms | Caller peak MB |
| --- | ---: | ---: | ---: | ---: |
| calc | 4,056 | 0.186 | 0.198 | 0.056 |
| edn | 12,242 | 0.602 | 0.630 | 0.269 |
| pikchr | 222,741 | 7.149 | 10.948 | 1.413 |
| calc already formatted | 4,082 | 0.170 | 0.198 | 0.056 |
| edn already formatted | 12,291 | 0.646 | 0.702 | 0.269 |
| pikchr already formatted | 222,542 | 7.086 | 7.569 | 1.413 |
| 128 plain rules | 4,224 | 0.567 | 0.845 | 0.434 |
| 512 plain rules | 16,896 | 2.367 | 2.571 | 1.556 |
| 2,048 plain rules | 67,584 | 9.413 | 15.558 | 5.235 |
| 2,048 tiny code fragments | 61,440 | 8.869 | 9.924 | 6.404 |
| 2,048 disabled regions | 122,880 | 6.631 | 8.614 | 13.780 |

Plain rules have named actions and no embedded Zig. Code cases contain one tiny statement fragment per rule; their worker memory is not counted in the caller peak. Disabled cases have one protected rule, one enabled rule, and paired formatter-control comments per generated unit. Ordinary inputs show roughly linear timing over these sizes. That does not establish linearity of all search paths.

Already-formatted samples produce the exact same output lengths and hashes as the first-pass references, but still take similar time and logical caller allocation volume. There is no cheap document-wide no-op exit in this baseline.

## Adversarial scaling

Each `drops` unit is an identical same-LHS rule containing four long symbols and a long named action, forcing layout splitting and dropping within one run. There are no Zig jobs in these cases.

| Rules in one run | Input bytes | Median ms | Caller peak MB |
| --- | ---: | ---: | ---: |
| 16 | 1,904 | 2.722 | 1.123 |
| 32 | 3,808 | 18.688 | 4.059 |
| 64 | 7,616 | 131.774 | 14.450 |
| 128 | 15,232 | 1,010.539 | 42.860 |

Doubling the run increases time 6.87×, 7.05×, and 7.67×: a practical witness of the cubic fitting path. A 15 KB grammar consumes roughly one second and 43 MB at the caller allocation boundary. The warmed caller arena does not repair the algorithm: the 128-rule case takes 1,098.898 ms, with 113.954 MB of logical peak bytes and 515,667 resize attempts.

Each `wide_rhs` case has a single rule with the listed number of particles and a short action. Each `macros` case has one declaration code block with that many unique `%ifdef` / declaration / `%endif` groups.

| Particles / macro groups | Wide RHS median ms | Macro block median ms |
| --- | ---: | ---: |
| 16 | 0.024 | 0.043 |
| 32 | 0.086 | — |
| 64 | 0.282 | 0.273 |
| 128 | 0.919 | — |
| 256 | 3.433 | 3.277 |

Wide RHS timing approaches quadratic scaling, consistent with materializing and rescanning every candidate split. The 256-particle input is just 1,555 bytes but has 2.016 MB of caller logical peak allocations. Macro scaling is also substantially superlinear; its worker allocations are hidden from caller counters. Source inspection is needed to attribute the measured cost to specific passes.

## Worker retention

A separate probe submits identical `x=1;` statement jobs to the production queue, waits for `finish`, and then reads `queue.arena.queryCapacity()` while the worker is drained. It sums successful result lengths before deinitializing the queue. Job arrays are allocated separately with SMP and are excluded from the capacity figure.

| Jobs | Retained arena capacity bytes | Result bytes | Capacity / result bytes |
| --- | ---: | ---: | ---: |
| 1 | 3,872 | 10 | 387× |
| 64 | 213,052 | 640 | 333× |
| 256 | 678,728 | 2,560 | 265× |
| 1,024 | 2,751,520 | 10,240 | 269× |

The queue retains about 2.75 MB for 10 KB of final results after 1,024 tiny jobs. Capacity includes spare space and temporary allocations retained by arena semantics; it is not an exact accounting of AST bytes. It directly demonstrates that the queue's lifetime retains substantially more storage than its final results require.

## Validation and limits

The benchmark completed all 27 cases in both allocator modes, checked fixture parse validity, stable output bytes, and zero logical outstanding caller allocations after freeing each probe result. The worker probe succeeded for all four job counts. The surrounding formatter suite passed 40 tests, and `zig build test --summary failures` passed, including the stdio smoke test, in the audit task. No production formatter code was changed.

Internal arena prewarming cannot be benchmarked independently through the current public `format` interface. The caller-arena comparison is intentionally not presented as that experiment. This baseline also does not isolate external `zig fmt` process spawning, linked Zig AST parsing from rendering, or the exact allocation count within the worker arena. Its strongest measurements are end-to-end formatter timing, layout-only adversarial growth, and retained worker capacity.
