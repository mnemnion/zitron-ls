# Quadratic formatter fitting

2026-09-12; reference commit `9ee2219` (`perf: low-hanging fruit`). Zig 0.16.0,
ReleaseFast, tree-sitter-zitron `7f2726a`. Production changes are confined to
`src/format.zig`; the benchmark and formatter tests were extended alongside it.

The greedy search, score ordering, candidate ordering, layout thresholds,
comment handling, dropped-tail alignment, and final output are preserved.
Candidates now describe geometry with numbers, and candidate scoring reuses
prefix and suffix calculations within each fitting iteration.

## Measurements

The [complete results](format-benchmark-fitting.csv) contain 31 fixtures in two
caller-allocator modes. All 54 measurements corresponding to the prior 27
fixtures have exactly the same output length and hash as the
[cleanup baseline](format-benchmark-cleanup.csv). Four additional fixtures extend
run lengths to 512 rules and RHS lengths to 1,024 particles.

Direct SMP medians, 11 repetitions after warmups. Milliseconds and decimal MB;
memory is logical caller-boundary peak allocation, excluding the independently
allocated Zig worker, runtime allocations, and parsing.

| Case | Cleanup ms | New ms | Cleanup peak MB | New peak MB |
| --- | ---: | ---: | ---: | ---: |
| 128 difficult rules | 1,074.224 | 7.751 | 42.890 | 1.404 |
| One 256-particle rule | 3.541 | 0.099 | 2.427 | 0.054 |
| 2,048 ordinary rules | 8.856 | 7.516 | 5.328 | 2.781 |
| 2,048 tiny code fragments | 7.018 | 7.166 | 5.171 | 2.710 |

The 128-rule case is about **139 times faster**, with about **97% less caller
peak allocation**. The 256-particle case is about **36 times faster**.

| Difficult rules in one run | New median ms | Ratio to preceding size |
| --- | ---: | ---: |
| 16 | 0.178 | — |
| 32 | 0.550 | 3.09 |
| 64 | 2.172 | 3.95 |
| 128 | 7.751 | 3.57 |
| 256 | 30.174 | 3.89 |
| 512 | 110.414 | 3.66 |

The old sequence approached eightfold cost on doubling; the new sequence is
consistent with quadratic scaling. One 1,024-particle rule takes 0.391 ms;
RHS scaling is now dominated by collection and emission rather than exhaustive
construction of every split.

Ordinary sample timing varies enough that the complete run should not be read
as a precise attribution of small changes. A separate 51-repetition paired EDN
check compiled the committed formatter and the new formatter against the same
worker and grammar sources. [Reference](format-benchmark-fitting-edn-reference.csv)
and [confirmation](format-benchmark-fitting-edn-confirmation.csv) retain all rows:
EDN medians were 0.538 versus 0.522 ms; already-formatted EDN was 0.534 versus
0.564 ms. Its caller peak increases from about 235 KB to 328 KB. Cached metadata
and allocator chunk boundaries have a real small-input storage cost; this is
not an across-the-board memory reduction.

Reproduce with:

```sh
zig build bench-format -Doptimize=ReleaseFast -- 11
zig build bench-format -Doptimize=ReleaseFast -- 11 drops
zig build bench-format -Doptimize=ReleaseFast -- 11 wide_rhs
```

The usual global-cache permission error required the existing
`ZIG_GLOBAL_CACHE_DIR=/tmp/lsp-zitron-format-cleanup-cache` workaround during this
run. Measurement boundaries match the existing benchmark: parsing, verification,
caller frees, and caller-arena reset are outside the timer. No concurrent builds
ran during timed measurements. The temporary reference build switch was removed.

## Representation and search

Each particle stores its cumulative width. A pattern stores its split position,
indentation choice, line count, maximum/last widths, and aggregate overflow.
Original line breaks remain in the particles. No candidate line strings are
allocated. The final rendering pass writes those particles and delimiters once.

As a split moves right, its first line grows and its last line shrinks. Binary
search selects the last split satisfying `last_width >= first_width`, preserving
the original split-1 fallback. Each rule caches only the two winning split
indices. Candidate widths are then derived in constant time from prefix widths.
The initial geometry work is linear in source/particle size plus logarithmic
split searches, rather than quadratic copying of rule text.

## Scoring and nonlocal state

At each fitting iteration, prefix/suffix summaries record the facts needed by
`columnFor`: active pattern maxima, tail-width maxima, tail presence, and pulled
comments. Combining the prefix, replacement, and suffix produces a candidate's
alignment column in constant time.

Candidates are grouped by alignment column. Within a group, the scorer computes
the original run's prefix scores and closing columns once. A replacement's score
is that prefix, its own contribution, and a memoized suffix score keyed by the
incoming closing state. Entries are computed with an explicit path buffer;
there is no recursion proportional to run length.

The state bounds follow the existing `dropColumn` contract:

- An inherited closing column greater than 100 is unusable and shares the
  no-closing state.
- For a dropped action of width `w`, closing columns below `w + 4` are also
  unusable. Only the usable interval needs distinct cache entries.
- Rows which reset closing state need one entry. Comments with no rule preserve
  the state and contribute no score; suffix evaluation advances past them.
- Alignment columns 0 through 100 have separate groups. Columns above 100 share
  the group for 101. Every scored inline tail overflows in that group; the
  difference in excess is exactly `(actual_column - 101) * inline_tail_count`.
  Dropped-tail behavior is unchanged throughout that range.

Cache generations advance for each group. Scratch arrays retain capacity across
iterations and runs, but scores from an earlier snapshot are never reused after
accepting a change. A candidate carries its original enumeration ordinal so
grouping cannot alter ties after `Score.less` and `ruleLess`.

For a run of `n` items, there are O(n) greedy iterations and O(n) candidates per
iteration. The number of alignment groups and closing states is bounded by the
fixed layout limits. Each suffix entry is computed once per group, yielding
O(n²) fitting work and O(n) scratch space, apart from the existing lexical
tie-comparison cost when rule text itself is large. Actual caches allocate only
the row states that can matter, and visit only requested states.

The final undropping behavior is retained. Adding inline tails only increases
its active maxima, while padding can decrease from three spaces to two at most
once. That limits reconsideration; its existing per-candidate run scans do not
reintroduce the greedy fitter's cubic search.

## Validation

Test builds retain the exhaustive calculations as a reference:

- Numeric patterns are compared with the previous string-building calculation,
  including exact emitted bytes. Binary-selected cuts are compared with an
  exhaustive split search.
- Every fitted candidate's column and score are checked against full run scans.
  Every accepted winner is checked against the original enumeration order.
- 160 deterministic randomized run snapshots exercise replacements, changing
  run sizes, comments, dropped tails, block state, and large columns. Additional
  checks enumerate every incoming closing state for selected snapshots.
- 96 generated grammars check varied runs and semantic-token preservation while
  those candidate comparisons are active.

`zig build test --summary failures` passes, including formatter contracts,
worker regressions, LSP/module tests, and the stdio smoke test. Existing sample
parseability/idempotence and all prior golden tests remain in place. The
exhaustive assertions and reference helpers are excluded from non-test builds.

No allocator changes, worker changes, layout policy changes, staging, or commits
are included in this pass.
