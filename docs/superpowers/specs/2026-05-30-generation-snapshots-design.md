# Generation Snapshots Design

## Context

`lsp_zitron` crashed while handling rapid edits in a large `.zy` file. The fresh
macOS crash report showed the ZLS reader thread translating diagnostics through
`SpanTranslator.generatedPositionToSource` while the main LSP thread was syncing
the same document through `middlewareSyncDocument`.

The current middleware stores mutable document state in `GeneratedDocument`:
source text, generated text, code map, translator cache, diagnostics, version,
and open state all live together. The ZLS reader thread can translate diagnostics
through that state while the main thread rewrites it for a newer edit. This can
mix source text from one edit with generated text or code map data from another.
Older logs also show an alignment panic while iterating `middleware.documents`
from the ZLS diagnostic path during shutdown, which points at the same shared
state problem.

The fix should not be a narrow mutex patch only. The desired direction is to make
document generations explicit, because that gives the server the same shape it
will need for proper asynchronous operation later.

## Design Goal

Make generation snapshots the synchronization unit for all translation and
diagnostic work.

A generation is created by one source document sync. It has a monotonic local
generation id, source URI, source version, source text, generated URI, generated
text when available, code map when available, and diagnostics. Once published,
the generation's identity, source text, generated text, and code map are
immutable.

The live document record should become small:

```text
source_uri -> {
    current_generation,
    latest_requested_version,
    in_flight_generation?,
    lifecycle/open state,
}
```

Any code that needs translation must choose a generation first and then translate
only through that generation. No operation may mix current mutable document
fields while translating.

## Invariants

- Published generation text and code maps are immutable.
- Translation reads from one generation only.
- A stale generation build must not replace a newer published generation.
- ZLS diagnostics must not mutate or translate through current document state
  unless they can be attached to a specific generation.
- If an operation cannot prove which generation it belongs to, it must not
  mutate or translate against current document state.
- User-facing request lapping behavior is deferred, but request forwarding and
  translation APIs should force callers to choose a generation handle.

## Lapping Policy

| Operation | Generation source | If lapped | Initial policy |
| --- | --- | --- | --- |
| `textDocument/didOpen` / `textDocument/didChange` | Creates a new generation build input. | An older build finishes after a newer edit was requested. | Discard the stale generation output and log at debug level. |
| Zitron generation result | Source version captured when the build started. | Current requested source version moved past it. | Do not publish; free temporary output and diagnostics. |
| Code map / source text / generated text | Owned by the published generation. | Not mutable after publish. | Safe to read through a generation handle. |
| Translator cache | Owned by a generation but may remain mutable. | Shared reader/main access is possible. | Guard cache mutation, or remove caching from shared paths until ownership is clean. |
| ZLS `didOpen` / `didChange` sent by us | Generated URI plus generated version derived from the generation. | A later source generation is sent before ZLS responds. | Later diagnostics can be stale and must be checked before translation. |
| ZLS diagnostics with a version | Generated URI plus diagnostic version. | Diagnostic version is not the latest published generation for that generated URI. | Drop and log at debug level. |
| ZLS diagnostics with `version = null` | No authoritative version. | Ambiguous if a generation is in flight or a newer generated sync was sent. | Accept only if exactly one latest published generation is unambiguous and no newer generated sync is pending or in flight; otherwise drop and log. |
| Hover/completion/definition/references/inlay/document symbols/rename | Generation chosen at request start. | Detailed behavior deferred. | Route through generation handles; do not design retry/drop policy in this phase. |
| Close document | Document lifecycle. | Diagnostics arrive after close. | Drop; no reachable generation should be mutated. |
| Shutdown/deinit | Server lifecycle. | Reader thread can still receive ZLS messages. | Stop or drain reader ownership before freeing generations and maps. |

## `version = null` Policy

ZLS diagnostics without a version are non-authoritative. That should not happen
for the behavior `lsp_zitron` wants to rely on, but the server must handle it
defensively.

Initial compatibility rule:

```text
Accept version-null diagnostics only when the generated URI has exactly one
unambiguous generated sync for that source, the current published generation is
the generation last sent to ZLS, and no generation for that source is in flight.
```

Otherwise, drop the diagnostics and log the reason. This keeps compatibility
with benign ZLS behavior without allowing ambiguous diagnostics to touch current
state.

## Generation Build Flow

1. Receive `textDocument/didOpen` or `textDocument/didChange`.
2. Capture a build input: source URI, source version, source text, and source
   parse root.
3. Run Zitron into temporary storage.
4. Parse grammar diagnostics from Zitron stderr.
5. If Zitron produced stdout, build a code map against that generated text.
6. Before publishing, compare the build input version with the document's latest
   requested source version.
7. If the build is stale, discard all temporary generation state and log it.
8. If current, publish the generation atomically.
9. If the generation has generated text, send `didOpen` or `didChange` to ZLS
   using the generation's generated URI and version.
10. If the generation has no generated text, do not send a generated update to
    ZLS.

There is no generation status field. If Zitron exits nonzero but produces
stdout, the stdout is the generation's generated text. The generation also
carries the parsed Zitron diagnostics. If Zitron fails without stdout, the
generation can carry grammar diagnostics or an error, but it does not provide a
generated document for ZLS.

## Diagnostic Flow

1. ZLS reader receives `textDocument/publishDiagnostics`.
2. Resolve the generated URI and diagnostic version to a published generation.
3. If the version is `null`, apply the compatibility rule above.
4. If no generation can be resolved, drop and log.
5. Translate diagnostics through that generation's source text, generated text,
   and code map.
6. Store translated ZLS diagnostics on the source document only if the generation
   is still the current published generation.
7. Publish source diagnostics for that generation.

This allows stale diagnostics to be harmless. A stale diagnostic may be parsed,
but it must not update the current source document.

## Concurrency Model

The design requires one owner policy for live document records. Two
implementation shapes are acceptable:

- Protect the document table and generation publication with a document mutex.
- Move ZLS reader effects onto a main-owner queue and make the reader thread only
  parse and enqueue messages.

The first implementation may use a mutex if that is the smallest safe step. The
important design point is that the mutex protects publication and generation
lookup; it is not the semantic model. The semantic model is explicit generation
ownership.

Translator caches are not part of the published generation snapshot in the
initial implementation. Translation paths use per-operation caches so source
text, generated text, and code maps remain the only shared generation inputs.

## Deferred User-Facing Request Policy

Detailed stale behavior for hover, completion, definition, references, inlay
hints, document symbols, and rename is deferred. These are structurally harder to
lap in normal use because users rarely issue them milliseconds after an edit.

This design still requires the APIs to make generation choice explicit. A later
phase can decide whether a lapped user-facing request completes against its
starting generation, retries on the current generation, returns null, or reports
request failure.

## Logging

Use quiet logs by default:

- `debug`: stale generation discarded, stale diagnostics dropped,
  `version = null` diagnostics accepted or dropped, request generation chosen.
- `warn`: generated URI believed to be owned but resolving to no generation,
  publish invariant violation, malformed ZLS diagnostics after JSON parse.

Internal lapping should not create user-facing diagnostics by default.

## Testing Plan

- Unit-test generation lookup by generated URI and generated version.
- Unit-test stale generation discard: generation N finishing after generation
  N+1 is requested must not publish N.
- Unit-test `version = null` diagnostics acceptance and rejection.
- Middleware-test ZLS diagnostics for generation N arriving after generation
  N+1 is published; they must not update current diagnostics.
- Middleware-test diagnostics arriving while a new generation is in flight; they
  must not read partially updated text or code maps.
- Regression-test shutdown or close while diagnostics arrive; the reader path
  must not iterate or mutate freed document state.

The old crash does not need to be reproduced byte-for-byte. The test goal is to
make the invalid interleaving unrepresentable.
