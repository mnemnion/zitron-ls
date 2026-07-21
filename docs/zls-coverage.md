# ZLS Coverage


Reconciled against the ZLS `0.16.0` capabilities and typed
request/notification handlers, and against `lsp_zitron`'s advertised
capabilities and forwarding middleware, on 2026-07-20.  `build.zig.zon`
pins ZLS `0.16.0`; this list does not describe later ZLS `master`
behavior.

Legend:

- ✅ exposed to `.zy` clients
- 🧭 translated or otherwise adapted between generated Zig and Zitron
  source
- ❌ offered by ZLS but deliberately not exposed by `lsp_zitron`
- ⚪ implemented in ZLS but not advertised by ZLS
- `forwarded` below means routed through the in-process ZLS library,
  not a ZLS subprocess or a transparent JSON proxy


## Text Document Features

- [✅ 🧭] Completion
  - Forwarded only when the cursor maps to embedded Zig.  Zitron
    completions own the grammar regions.  ZLS trigger characters are
    merged with the Zitron triggers advertised to the client, and
    completion edit ranges are translated back to `.zy` coordinates.
- [✅ 🧭] Hover
- [✅ 🧭] Signature help
- [✅ 🧭] Declaration
- [✅ 🧭] Definition
- [✅ 🧭] Type definition
- [⚪] Implementation
  - ZLS has a handler, implemented with the same behavior as definition,
    but advertises `implementationProvider: false`.  `lsp_zitron` does
    not expose it.
- [✅ 🧭] References
  - Ordinary generated-Zig references are translated back to `.zy`.
    Terminal references also use ZLS to find uses of the generated
    token-enum member and merge those with grammar-side references.
- [✅ 🧭] Document highlights
- [✅ 🧭] Document symbols
  - Translatable generated-Zig symbols are merged with Zitron grammar
    symbols; generated-only symbols and ranges that cannot be mapped are
    omitted.
- [✅ 🧭] Rename
  - Forwarded in embedded Zig and implemented locally for grammar
    symbols.  ZLS workspace edits are restricted to edits that can
    be translated from the generated document back into the source
    document.
- [ ] Prepare rename
- [✅ 🧭] Inlay hints
  - A Zitron source range may cover several generated-Zig spans.  The
    middleware requests their generated bounding range, translates the
    returned hints, and drops hints outside mappable source.
- [   Code actions
  - ZLS advertises quick fixes, refactors, source actions, organize-
    imports, and fix-all actions.  Their workspace edits target
    generated Zig, so exposing them requires edit translation and a
    policy for actions that modify generated-only text.
- [ ] Document formatting
  - Formatting generated Zig is not equivalent to formatting the `.zy`
    grammar; generated-only text and line-marker layout have no direct
    source edit.
- [ ] Folding ranges
- [ ] Selection ranges


## Semantic Tokens

- [✅ 🧭] Full semantic tokens
  - ZLS tokens are filtered to mappable generated spans, translated
    to `.zy`, reordered into source order, and published with an
    `lsp_zitron` result ID.
- [✅ 🧭] Ranged semantic tokens
  - Client range requests are served by slicing the current translated
    source-side token collection.  On document changes, the middleware
    maps the dirty `.zy` range to generated spans, requests one bounding
    range from ZLS, filters the response against both that generated
    range and the source range being replaced, translates it, and
    splices it into the collection.
  - The filtering matters because the generated bounding range
    can contain gaps and generated-only code between source spans,
    and a server may return tokens which overlap a range boundary.
    Translating the unfiltered response would replace tokens outside
    the dirty `.zy` region or leak generated-only tokens into the source
    result.
- [✅ 🧭] Full semantic-token delta
  - This is supplied by `lsp_zitron`, not ZLS `0.16.0`.  ZLS exposes
    full and range requests but no delta handler.  `lsp_zitron` retains
    translated source-side snapshots and computes deltas between them;
    an unknown previous result ID correctly falls back to a full
    response.
- [✅] `workspace/semanticTokens/refresh`
  - `lsp_zitron` emits the refresh request itself after source changes
    when the client advertises support.  It also forwards ZLS refreshes
    emitted after a successful `build.zig` configuration reload.


## Diagnostics

- [✅ 🧭] `textDocument/publishDiagnostics`
  - Generated-Zig diagnostics are captured from the in-process ZLS
    transport, translated to `.zy`, merged with Zitron generator
    diagnostics, and published under the source URI and current source
    version.  Diagnostics outside mappable spans are omitted.
  - ZLS `0.16.0` ordinarily publishes diagnostics without a document
    version.  While a newer generated document is in flight, versionless
    diagnostics are rejected rather than risking a stale result; they
    are accepted only when the current generation is unambiguous.


## Document Synchronization

- [✅ 🧭] Open document
- [✅ 🧭] Change document
  - The client may send incremental `.zy` changes, but ZLS receives a
    whole-text replacement of the newly generated Zig document.  ZLS
    never sees `.zy` text.
- [✅ 🧭] Close document
- [❌] Save notification
- [❌] Will-save-wait-until edits
  - ZLS uses this for its autofix-on-save mode.  `lsp_zitron` neither
    advertises save synchronization nor forwards save lifecycle events.


## Workspace Features

- [ ] Workspace symbols
  - ZLS can search Zig symbols across its workspace, but results
    may name source files as well as synthetic generated documents.
    URI/range translation and a policy for non-generated Zig results are
    still needed.
- [ ] Workspace folders and folder-change notifications
- [ ] Workspace configuration
- [✅] Watched `build.zig` files
  - When the client supports watched-file dynamic registration,
    `lsp_zitron` registers `**/build.zig` for change events only.  Matching
    filesystem notifications call the in-process ZLS document store's
    build-file invalidator directly.  ZLS's language-server watched-file
    handler requires files to be present in its document cache, while a
    lazily discovered `build.zig` may exist only in its build-file table;
    moreover, ZLS `0.16.0`'s non-delete refresh path rejects file-scheme
    URIs.  Using the library API covers both cases.  Create/delete events,
    other Zig files, and editor change notifications are not forwarded.
- [🧭] Dynamic registration for configuration and watched files
  - `lsp_zitron` dynamically registers the narrow `build.zig` watcher it
    needs.  ZLS configuration registration and its broader Zig/ZON watcher
    are intentionally not exposed.
- [ ] `workspace/applyEdit` requests
  - ZLS uses this for one autofix-on-save mode.  The embedded adapter
    does not tell ZLS that apply-edit is supported, and captured ZLS
    requests are not relayed to the client.
- [✅] `workspace/inlayHint/refresh`
  - The embedded adapter advertises refresh support to ZLS.  After a
    successful `build.zig` configuration reload, captured refresh requests
    are re-originated toward clients which advertised support.  This is a
    global invalidation signal, so no grammar-range translation is needed;
    the client's follow-up inlay-hint requests recompute the normal merged
    Zitron and ZLS results.


## ZLS Lifecycle and Capability Adaptation

- [✅] In-process initialize/initialized lifecycle
  - The adapter initializes ZLS once as an internal UTF-8 client.
    The external client negotiates its own position encoding with
    `lsp_zitron`; source/generated translation bridges that boundary.
- [✅] Completion trigger discovery
  - The adapter retains ZLS's advertised trigger characters for the
    combined external capability.
- [ ] ZLS `window/showMessage` notifications
- [ ] ZLS work-done progress
- [ ] ZLS shutdown/exit forwarding
  - ZLS is library-owned and destroyed with the middleware, so its
    protocol shutdown/exit lifecycle is not exposed as a second server
    lifecycle.


## Summary: ZLS Features Still Hidden

- Prepare rename
- Code actions
- Document formatting
- Folding ranges
- Selection ranges
- Workspace symbols
- Save and will-save-wait-until behavior
- Workspace folders, configuration, and watched-file integration
- ZLS-originated apply-edit, inlay-refresh, show-message, and progress
  messages

Implementation is not the only missing piece for most of these.
Anything that returns locations, ranges, symbols, or edits must
be mapped from the synthetic generated Zig document back to `.zy`;
workspace-wide operations also need an explicit policy for real Zig
files versus synthetic generated documents.
