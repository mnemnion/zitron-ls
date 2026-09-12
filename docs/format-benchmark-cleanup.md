# Formatter cleanup measurements

Captured 2026-09-12, Zig 0.16.0, `ReleaseFast`, following the straightforward
cleanup of formatter HEAD `639fe86`. The cubic fitting algorithm, candidate
strings, greedy scoring, and tie order are unchanged.

The complete run used `zig build bench-format -Doptimize=ReleaseFast -- 11`.
All 27 fixtures in both allocator modes retain the baseline output lengths and
Wyhash values. [Complete results](format-benchmark-cleanup.csv) use the same
measurement boundary and counters as the
[baseline](format-benchmark-baseline.md). Caller counters still exclude worker
allocations. Plain Zig encountered a global-cache `PermissionDenied`; subsequent
commands used `ZIG_GLOBAL_CACHE_DIR=/tmp/lsp-zitron-format-cleanup-cache` as an
environment workaround. No competing builds ran during timing.

## Representative results

Direct SMP, milliseconds, 11 repetitions after two warmups:

| Case | Baseline | Cleanup | Caller peak bytes, before → after |
| --- | ---: | ---: | ---: |
| calc | 0.186 | 0.150 | 55,838 → 34,692 |
| edn | 0.602 | 0.490 | 269,283 → 235,468 |
| pikchr | 7.149 | 6.408 | 1,412,866 → 727,517 |
| 2,048 tiny code fragments | 8.869 | 7.018 | 6,403,808 → 5,171,042 |
| 2,048 disabled regions | 6.631 | 4.678 | 13,779,732 → 6,476,528 |
| 256 macro groups | 3.277 | 0.258 | 69,573 → 79,277 |
| Difficult 128-rule run | 1,010.539 | 1,074.224 | 42,860,239 → 42,890,150 |
| Single 256-particle rule | 3.433 | 3.541 | 2,016,035 → 2,427,217 |

These are end-to-end observations, not isolated attribution to each edit.
The difficult layout cases retain their previous scaling. Some logical peaks
increase because arena reservation and chunk boundaries change; reservation is
not an across-the-board memory reduction.

The initial already-formatted pikchr median was **64.518 ms**, an outlier retained
in the complete CSV. A separate
[pikchr confirmation run](format-benchmark-cleanup-pikchr-confirmation.csv)
measured 7.088 ms for the original input and **6.407 ms** for the already-formatted
input (baseline 7.086 ms). A
[macro confirmation run](format-benchmark-cleanup-macros-confirmation.csv), after
bounding long marker-digit lookalikes, measured **0.295 ms** for 256 groups.
Confirmation hashes also match baseline. Timings are descriptive local runs,
not isolated-machine confidence intervals.

## Worker retention and lifetimes

[Worker results](format-benchmark-worker-cleanup.csv) report both arenas after
`finish()`, before releasing either. Final fragments are copied into result
storage; ASTs, wrappers, maps, and restoration buffers occupy reusable scratch.
Both arenas use SMP backing and have exclusive worker ownership until drain.

| Jobs | Old combined arena | Result arena | Scratch arena | New total |
| --- | ---: | ---: | ---: | ---: |
| 1 | 3,872 | 52 | 6,182 | 6,234 |
| 64 | 213,052 | 692 | 6,182 | 6,874 |
| 256 | 678,728 | 3,318 | 6,182 | 9,500 |
| 1,024 | 2,751,520 | 13,992 | 6,182 | 20,174 |

At 1,024 jobs, total retained capacity falls **99.3%**, while the 10,240 bytes of
results remain alive. A regression explicitly releases scratch after a mixed
successful/failed job sequence, then verifies every surviving result.

Worker scratch reserves at least 4 KB when first needed and retains at most
256 KB between jobs. Large jobs can exceed that cap while executing. The
single-job retained footprint therefore increases; the reserve trades a small
initial budget for fewer cold allocation steps. Document scratch reserves four
times input length, capped at 256 KB, and collection reserves the root child
count. These bounded initial budgets were not independently ablated: the table
measures the whole cleanup. An empty queue allocates no worker storage and
starts no worker. Neither arena survives a formatter call; caller-arena warming
still does not mean cross-request reuse of formatter scratch.

## Alias and collision probes

`zig build bench-format -Doptimize=ReleaseFast -- 11 aliases` adds two optional
131–133 KB statement fixtures with one long alias. The collision case embeds
all 52 alphabetic candidate prefixes in an opaque literal, forcing the final
underscore candidate. They retain substring collision semantics inside literals.

| Direct SMP probe | Reference ms | Cleanup ms |
| --- | ---: | ---: |
| Sparse alias, 131,205 bytes | 0.816 | 0.683 |
| 52 colliding prefixes, 133,337 bytes | 1.524 | 0.761 |

[Reference](format-benchmark-aliases-reference.csv) uses HEAD formatter algorithms
with its prohibited worker allocator replaced by SMP; it is a separately labeled
reference, not a replacement of the original baseline. The
[cleanup results](format-benchmark-aliases-cleanup.csv) have identical output
lengths and hashes. Caller peaks increase from 433,530/440,458 to 590,213/593,411
bytes for these large-literal fixtures because of document reservation.

Alias substitution allocates one candidate buffer. The common first candidate
uses one source search; on collision, a monotone suffix search builds a 256-bit
prefix-presence mask. `$$` uses a lazy 8 KB byte-pair bitmap. Macro markers are
indexed once, and verification advances through marker-looking output once.
Only canonical, bounded-width `usize` number/salt prefixes enter the marker map.
A 64 KB digit-run regression verifies that the index has at most the machine's
maximum decimal width in entries, while valid prefix collisions still match.

## Audit disposition

| Audit finding | Disposition |
| --- | --- |
| 1: Numerical layout candidates | Deferred to the cubic fitting change; speculative pattern construction is unchanged. |
| 2: Run scoring and candidate summaries | Deferred; exact scoring, undropping retries, and tie order are unchanged. |
| 3: Allocator and worker scratch ownership | Fixed within a call: SMP backing, separate result/scratch arenas, retained bounded scratch, lazy allocation. Cross-request formatter context remains deferred because it requires explicit server ownership and concurrency policy. |
| 4: Restoration and redundant Zig parse | Unmodified output is borrowed; substitutions restore unchanged spans in chunks. Wrappers/transformed linked inputs are sentinel-terminated directly. Linked statement boundaries use a validated lexical brace walk over trusted rendered output. External statement output retains AST validation; external declaration input stays borrowed when possible. |
| 5: Final output copy | Rendering owns a caller-allocated, source-sized initial buffer and returns its owned slice. Allocator finalization may still resize/copy. |
| 6: Normalization and tiny temporaries | Lazy borrowed normalization covers symbols, parameters, actions, and comments. Action arity uses two-token lookahead. `%impl` avoids discarded prefix normalization. Failed compaction releases its lazy output. Fixed-delimiter action/code wrappers remain strings because their lengths/spellings participate throughout layout; changing that representation belongs with layout geometry. |
| 7: Collision searches | Bounded pair bitmap, reusable alias candidates/prefix mask, one marker index, and cursor-based marker verification. A distinct alias can still require one common probe plus one source suffix scan; no large substring dictionary is built. |
| 8: Local passes | Initial patterns are built when ditto columns finalize; `fit` reports new blocks; child handles/comment status share a traversal; gap newline counts are reused; newline style is recorded during the existing source scan. Immutable width caches and reusable scoring/run summaries remain with layout work. |
| 9: Empty worker setup | Worker starts only on first submission. Synchronous fallback remains. Batching and synchronous crossover thresholds need a dedicated scheduling comparison and are deferred. |
| 10: No-op LSP timing | Both changed and unchanged results log elapsed time and `changed`. |

## Validation

The formatter contract suite covers semantic token preservation and sample
idempotence, aliases/macros/lookalikes, controls and literal bytes, invalid Zig
and external errors, and width thresholds. Added cases exercise lexical braces
in linked wrapper extraction, source-wide substring and marker-prefix collisions,
and comment-only CRLF input. Separate worker unit tests cover scratch/result
lifetimes with failed neighbors and bounded long-digit marker indexes.

Final validation: `zig build test --summary failures` (including formatter tests,
worker tests, LSP/module tests, and stdio smoke); `zig fmt` on edited Zig files;
`git diff --check`. All original benchmark files and unrelated edits are retained.
