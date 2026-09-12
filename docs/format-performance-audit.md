# Formatter performance audit

Audited source: commit `639fe86`, Zig 0.16.0, 2026-09-12. Scope includes the
complete standalone formatter, embedded Zig formatting, and the LSP formatting
handler. Production code is unchanged. The companion benchmark harness and
[baseline report](format-benchmark-baseline.md) make subsequent changes measurable.

The dominant structural problem is speculative layout: whole strings are built
to evaluate numerical choices, and whole runs are rescored for each choice.
The embedded Zig path also has a cold, hardcoded page-backed arena, retains
temporary allocations across jobs, reparses rendered statement wrappers, and
copies output during restoration even when nothing was substituted.

## Measured baseline

`ReleaseFast`, 11 measured repetitions after warmups, existing parse supplied.
These are formatter-call medians; allocation figures exclude the independent
Zig worker unless explicitly described as worker capacity.

| Case | Time | Allocation finding |
| --- | ---: | --- |
| calc, 4 KB | 0.186 ms | 56 KB logical caller peak |
| edn, 12 KB | 0.602 ms | 269 KB logical caller peak |
| pikchr, 223 KB | 7.149 ms | 1.41 MB logical caller peak |
| Difficult run, 16 rules | 2.722 ms | 1.12 MB logical caller peak |
| Difficult run, 32 rules | 18.688 ms | 4.06 MB logical caller peak |
| Difficult run, 64 rules | 131.774 ms | 14.45 MB logical caller peak |
| Difficult run, 128 rules, 15 KB | 1,010.539 ms | 42.86 MB logical caller peak |
| One 256-particle rule, 1.6 KB | 3.433 ms | 2.02 MB logical caller peak |
| 1,024 tiny Zig jobs | Separate retention probe | 2.75 MB worker arena capacity for 10 KB of results |

Doubling the difficult run costs approximately seven to eight times as much,
matching the cubic candidate-scoring path. Warming the caller arena leaves the
128-rule case at 1.099 seconds. Ordinary sample timings are much smaller; the
adversarial case exposes scaling that those samples would otherwise conceal.
Raw results, no-op samples, percentile definitions, and allocation-accounting
limits are in the [baseline report](format-benchmark-baseline.md).

## Allocation ownership and warming

| Storage | Current lifetime and backing | Finding |
| --- | --- | --- |
| Document scratch | New `ArenaAllocator` backed by the caller allocator on every `format()` | No preallocation or retained capacity across calls |
| Embedded Zig work and results | New `Queue.arena` backed directly by `std.heap.page_allocator` | Replace this backing choice; no new use of `page_allocator` is authorized |
| Zig ASTs, substitution tables, wrapper buffers | Same queue arena as finished results | Temporary storage accumulates across fragments |
| Final text | Rendered into document scratch, then duplicated into caller storage | One avoidable complete-output copy |
| LSP result | Caller is the request arena | Formatter scratch is nested in request storage; it is not persistent formatter scratch |

Locations: [`format()`](../src/format.zig#L17),
[`Queue.init/process`](../src/format/ZigCode.zig#L26),
and [the LSP handler](../src/lsp_zitron.zig#L402).

Neither internal arena has a warm-up allocation, a retained-capacity reset, or a
lifetime spanning requests. Repeatedly calling the formatter with a warmed
*caller* arena does not warm the queue arena or preserve the document arena's
own allocation state.

The queue keeps all jobs' results alive until rendering ends, which is required
by current ownership. Keeping all their parsing and transformation scratch alive
that long is unnecessary. `ast.deinit()` and `free()` do not generally reclaim
older allocations from an arena. In particular, rendering allocates output after
the first AST, and restoration allocates output after the second AST.

A suitable repair is an explicitly owned reusable formatter context: separate
result storage from document scratch and worker scratch, use an appropriate
general-purpose backing allocator, and reset worker scratch between fragments.
Copying the *finished* fragment into result storage is justified if it allows
the much larger scratch region to be reused. Reset retained scratch only after
all consumers have finished; keep worker allocation ownership safe for concurrent
execution. Size/prewarm it from measured workloads after eliminating speculative
allocation. Do not retain an enormous bad-layout high-water mark indefinitely.

## Findings, in recommended order

### 1. Replace string-valued layout candidates with numerical descriptions

[`balancedPattern()`](../src/format.zig#L665) calls
[`makePattern()`](../src/format.zig#L409) for every possible particle split.
Each call allocates and copies the entire rule into line strings, then scans
those strings to compute widths. All rejected alternatives remain in document
scratch. `fit()` repeats this for unchanged rules on later iterations.

For `p` particles and `B` rule bytes, one balanced-pattern search does
`O(p * B)` copying/scanning and retains comparable speculative storage. For
bounded particle lengths, that is quadratic in particle count. The fallback
also rebuilds split 1 even though it was already evaluated.

Represent a pattern using particle ranges, indentation, split position, and
per-line widths. Cache particle widths and prefix sums. First-line width grows
as the cut advances and second-line width shrinks, so select the closest valid
crossing using binary search over those sums, preserving the existing
`last_width >= first_width` rule and split-1 fallback. Initial user line breaks
need their own range descriptors. Emit text once, after the winning layout is
known. Cache the two balanced alternatives per rule: their geometry does not
change when another rule's tail drops.

### 2. Stop rescoring entire runs for every speculative replacement

[`fit()`](../src/format.zig#L555) can accept changes over a number of iterations
proportional to run length. On each iteration it visits every eligible rule,
builds candidates, and calls [`consider()`](../src/format.zig#L653).
Each consideration invokes [`columnFor()`](../src/format.zig#L682), which makes
two run traversals, followed by [`score()`](../src/format.zig#L704), which makes
another traversal and rescans pattern and action strings for widths.

For a run of `r` rules of bounded size, this admits cubic work: `O(r)` accepted
changes times `O(r)` candidate rules times `O(r)` scoring. This is an upper-bound
analysis; normal runs which already fit exit quickly. Wider rules add the
speculative construction cost described above. Already exhausted rules are
still visited by the candidate loop.

Cache immutable widths and each rule's pattern-overflow contribution. Maintain
the maximum and runner-up active pattern widths, their multiplicities, maximum
eligible tail width, and pulled-comment state so a single replacement can
derive the candidate column without rediscovering those facts. Track eligible
candidate rules separately from exhausted rules.

Scoring is not wholly independent per rule: dropped-tail closing alignment
propagates through neighboring rules. Preserve that dependency and the exact
`Score.less`/`ruleLess` tie order. Recompute affected spans or cache suitable
summaries; do not replace the score with a sum of stale per-rule scores. Even
before that larger change, cached geometry eliminates repeated text scans and
candidate rebuilding.

### 3. Replace the queue's allocator and split temporary storage from results

[`Queue`](../src/format/ZigCode.zig#L16) hardcodes `page_allocator`, starts its
arena cold, processes all fragments through it, and releases it only at queue
destruction. This allocator choice and scratch lifetime should be addressed
together. Substitution maps, dedented buffers, wrappers, ASTs, rendered wrappers,
and restoration buffers all compete for that lifetime.

Measure both backing allocations and retained capacity. The ordinary allocator
passed to `format()` cannot observe allocations made by this independent queue.
A low caller allocation count is therefore not evidence of low total allocator
traffic. The worker-only benchmark exposes queue arena capacity after draining
the jobs; capacity is not a complete count of worker or OS allocations.

### 4. Avoid unconditional restoration and redundant Zig parsing

[`formatCode()`](../src/format/ZigCode.zig#L73) already avoids constructing
`prepared` when no substitution is required. However, it always constructs
`restored`, walks every output line and lexical token, and copies the whole body
even when `forward` and `macros` are empty. In that common case, return the
trimmed body slice. When edits exist, borrow unchanged spans and copy them in
chunks using a restoration cursor.

For statements, the linked path currently does:

1. Optional dedent copy.
2. Optional substitution copy.
3. Allocate a synthetic function wrapper.
4. Duplicate it with a zero terminator, parse it, and render it.
5. Duplicate the rendered wrapper with a zero terminator and parse it again to
   recover the body's byte offsets.
6. Copy the recovered body through restoration.
7. Potentially compact it into another string and allocate `{ ... }` around it.
8. Copy it into the final document and duplicate the complete document output.

The first sentinel copy can be avoided when constructing a wrapper or transformed
buffer by producing sentinel-terminated input directly. A borrowed declaration
slice may still need a sentinel copy for the AST API. The second full AST exists
only to locate the rendered wrapper's body. A validated token-based boundary
extraction can compute those offsets
without another AST; alternatively, a rendering interface that exposes output
boundaries could provide them. A naive search for the first/last brace is not
sufficient for lexical edge cases, comments, multiline strings, and formatting
controls. Keep validation of external formatter output.

### 5. Render directly into caller-owned output

[`render()`](../src/format.zig#L781) grows an unreserved byte list in the scratch
arena. `format()` then duplicates all of it into caller storage. Give rendering
its own result allocator/writer, reserve a measured initial capacity (source
length is a useful starting estimate, not an upper bound), and return ownership
of that buffer. This removes the explicit full-output duplication and avoids
pinning the rendered scratch buffer until document-arena destruction.
The owned-slice API can still need a final shrink/copy if the allocator cannot
resize in place; measure that rather than promising zero finalization copies.

For the LSP caller, the output allocation happens before scratch-arena teardown
and can also prevent older nested-arena chunks from being reclaimed individually
by the outer request arena. Persistent, separate scratch resolves that ownership
issue more directly than adding another arena layer.

### 6. Borrow already-normalized text and avoid tiny intermediate collections

[`normalize()`](../src/format.zig#L998),
[`normalizeParameter()`](../src/format.zig#L1055), and
[`normalizeComment()`](../src/format.zig#L1086) construct fresh output even when
the input already has the desired spelling. Ordinary terminal names and
nonterminal names therefore receive copies before pattern assembly copies them
again. Use a lazy output builder: compare desired emission against the borrowed
input and allocate only on the first difference, retaining a cursor into the
unchanged prefix. This avoids a separate normalize-then-compare pass.

[`normalizeAction()`](../src/format.zig#L1027) allocates an RHS slice array merely
to know whether there are zero, one, or multiple arguments. Two-token lookahead
is sufficient to choose punctuation and spacing; emit the rest with the
existing tokenizer cursor. No array is needed.

[`collectDirective()`](../src/format.zig#L221) normalizes a prefix before replacing
it with a newly allocated `%impl` plus normalized action when a named action is
present. Select that case before doing the discarded normalization. Represent
braces, `%impl `, and surrounding spaces as rendering metadata where practical,
rather than allocating a second string just to add fixed delimiters.

`compactCode()` already borrows a single-line body. For multiline bodies it can
allocate a partial result and later abandon it when an opaque construct prevents
compaction. A lazy builder and explicit compactability metadata can reduce that
waste; preserve literal bytes and `zig fmt: off` behavior.

### 7. Index substitution collisions once instead of searching from byte zero

[`substituteName()`](../src/format/ZigCode.zig#L216) scans the entire source for
each proposed identifier. Alias proposals additionally allocate a new string
before testing it; rejected proposals remain in scratch. The two-byte `$$`
replacement has a bounded but large search space. The forward/reverse maps
already avoid repeating the work for the same spelling, which is good.

[`uniqueMarker()`](../src/format/ZigCode.zig#L235) allocates and scans the whole
source per marker/salt. After restoration, another whole-output search runs for
every macro marker. With `m` macros and `B` body bytes, even collision-free marker
generation and verification do `O(m * B)` work.

Build a collision index once, and construct candidate names in reusable scratch,
allocating only accepted names. Preserve the current substring-collision
contract unless deliberately changing it: indexing only identifier tokens is
not automatically equivalent to the existing source-wide substring checks.
A compact presence table can cover two-byte candidates; macro identifiers can
be recognized/indexed in one pass. Restoration can verify marker occurrences
while advancing a cursor, without restarting one substring search per macro.

### 8. Fuse local passes where they carry the same information

Several complete phases are justified: collection may overlap Zig work, layout
needs all participating rules, and rendering needs the chosen layout. Combining
all of them into one pass would lose those dependencies.

Smaller repeated work is avoidable:

- [`prepare()`](../src/format.zig#L298) walks items to prepare results, calls a
  separate ditto/boundary walk, then walks again to construct patterns. Pattern
  descriptors can be prepared when ditto columns are finalized. Preserve the
  comment lookahead and blank-line mutations.
- [`layout()`](../src/format.zig#L440) counts every block before and after each
  fit cycle only to detect newly formed blocks. Have `fit()` report structural
  changes, then recollect runs only when needed. Reuse unaffected run metadata
  where the dependency permits it.
- `width()` repeatedly scans immutable LHS, particles, patterns, actions, and
  comments in hot loops. Compute width alongside normalization or initial
  collection and carry it with the slice.
- `firstChild()` restarts a tree walk for each requested child kind;
  `hasSyntaxComment()` separately traverses the syntax. Collect the needed
  child handles and comment status in one traversal. Current child-kind lookups
  are bounded in number, so this is a constant-factor improvement, below the
  layout complexity problems in priority.
- Gap newline counting and detection can share one result. Newline style can
  be recorded during the existing source scan instead of rediscovered in
  rendering. These are small linear passes, not the main bottleneck.

`undrop()` also scans the run and invokes `columnFor()` for each tentative
undrop. Reuse the same run summaries there. Do not simply delete its retry loop:
adding an inline tail can change the padding decision used by later candidates.

### 9. Start concurrency only when there is work; measure the crossover

`Queue.init()` requests a concurrent worker even for documents with no embedded
Zig jobs. The queue has a fixed buffer of 16 pointers and one consumer.
Many tiny jobs pay per-job synchronization, wrapping, parsing, and allocation.
Lazily starting the worker on the first job avoids the no-work setup; a measured
synchronous threshold or batching can help small fragments.

Do not assume each future creates an OS thread, and do not assume concurrency
is always a loss. Collection and Zig formatting can overlap on larger grammars.
Compare synchronous, queued, and batched paths under identical inputs before
choosing the crossover. The existing synchronous fallback is useful.

An explicitly configured external formatter spawns `zig fmt --stdin` once per
fragment, plus pipe handling. The default linked renderer avoids this process
cost. Keep external-mode timings separate; changing it requires preserving
fragment isolation and fallback semantics.

### 10. Include unchanged documents in timing visibility

The [LSP handler](../src/lsp_zitron.zig#L410) performs all formatting and compares
the full output with the source, but returns before logging when unchanged.
Repeated formatting of an already-formatted document is therefore invisible in
that metric. Log both paths, recording whether an edit was produced.

The benchmark measures the formatter over an existing parse, which matches the
handler's entry point. It does not include JSON serialization, transport,
client application of the whole-document edit, or the client's resulting
document-change processing. Those costs belong in a separate LSP end-to-end
measurement. A version/options keyed formatting cache may avoid repeat work,
but it is a later optimization with invalidation and storage costs.

## Searches and copies that already look sound

- Disabled intervals are ordered and [`protected()`](../src/format.zig#L288)
  uses binary search. Collection is monotone, so a retained interval cursor is
  a possible small improvement, not an urgent complexity fix.
- Main tree collection and RHS particles use tree cursors. Normal lexical
  loops advance offsets over opaque strings/comments rather than revisiting
  their interiors.
- Raw text, gaps, aliases, and failed Zig fragments generally borrow source
  slices. There is no blanket source clone merely in case mutation is needed.
- Copying a `Rule` into a candidate copies its slice descriptors, not the
  referenced strings. The excessive string work is in candidate construction.
- `dedent()` returns borrowed source when no removal is necessary. Determining
  the minimum indent before emitting is a legitimate dependency; its two
  passes should not be combined by guessing indentation.
- `prepared` is built only if substitutions exist. `compactCode()` borrows
  single-line input. Array lists use amortized growth and run storage retains
  capacity across recollection within one call.
- The formatter accepts the existing Tree-sitter root; it does not reparse the
  complete grammar inside `format()`.

## Validation and follow-through

The unchanged formatter passes all 40 standalone formatter tests with
`zig build test-format`. The full `zig build test --summary failures` also
passes, including the stdio smoke test. Formatter tests cover sample parseability and idempotence,
semantic token preservation, malformed fragments, substitutions, literal
preservation, controls, and layout thresholds. Keep those contracts while
changing representation and scheduling.

The baseline report records timings and allocation boundaries. Treat complexity
arguments above as source-derived unless a matching benchmark demonstrates the
growth. Allocation capacity is not RSS, and caller counters do not include the
independently allocated Zig worker arena or Tree-sitter/runtime allocations.

Implement in reviewable pieces: numerical candidate geometry; cached widths and
run facts; corrected allocator ownership and reusable scratch; copy/pass
elimination; then worker scheduling and any persistent caches. Re-run identical
baseline fixtures after each piece, compare output hashes, and retain the full
formatter contract suite. Warming an allocation-heavy algorithm alone would
hide allocator traffic while preserving its copying and excessive scratch use.
