# LSP Burndown

Reconciled against the advertised capabilities, request handlers, and smoke-test
surface on 2026-07-19.

Legend:

- ✅ implemented
- ⚡️ reaches through generated Zig/ZLS middleware where that makes sense
- `(no ⚡️)` implemented only for the Zitron grammar/source half
- ❌ not applicable to Zitron or the project's intended scope
- `resolve` is an optional follow-up request that fills in expensive item details

## Core Protocol

- [✅] Server initialization
- [✅] Server shutdown
- [✅] Server exit
- [✅] Position encoding negotiation
- [✅] Open/close document sync
- [✅] Incremental document change sync
- [✅] Full document change sync
- [❌] Save notifications
- [❌] Will-save notifications
- [❌] Will-save-wait-until edits
- [ ] Dynamic capability registration
- [❌] Client capability probing beyond current needs
- [ ] Request cancellation
- [✅] Progress reporting
- [ ] Partial result streaming
- [ ] `window/logMessage` notifications
- [❌] Telemetry events

## Text Document Features

- [✅ ⚡️] Completion
- [ ] Completion item resolve
- [✅ ⚡️] Hover
- [✅ ⚡️] Signature help
- [✅ ⚡️] Declaration
- [✅ ⚡️] Definition
- [✅ ⚡️] Type definition
- [ ] Implementation
- [✅ ⚡️] References
- [✅ ⚡️] Document highlights
- [✅ ⚡️] Document symbols
- [ ] Code actions
- [ ] Code action resolve
- [ ] Code lens
- [ ] Code lens resolve
- [ ] Document links
- [ ] Document link resolve
- [❌] Document colors
- [❌] Color presentations
- [ ] Document formatting
- [ ] Range formatting
- [ ] Ranges formatting
- [ ] On-type formatting
- [✅ ⚡️] Rename
- [ ] Prepare rename
- [ ] Folding ranges
- [ ] Selection ranges
- [✅ ⚡️] Semantic tokens, full
- [✅ ⚡️] Semantic tokens, range
- [✅ ⚡️] Semantic tokens, delta
- [❌] Monikers
- [❌] Linked editing ranges
- [ ] Call hierarchy prepare
- [ ] Call hierarchy incoming calls
- [ ] Call hierarchy outgoing calls
- [❌] Type hierarchy prepare
- [❌] Type hierarchy supertypes
- [❌] Type hierarchy subtypes
- [ ] Inline values
- [✅ ⚡️] Inlay hints
- [ ] Inlay hint resolve
- [ ] Pull diagnostics
- [✅ ⚡️] Push diagnostics
- [ ] Inline completions
- [ ] Document drop edits
- [ ] Paste edits

## Workspace Features

- [ ] Workspace symbols
- [ ] Workspace symbol resolve
- [ ] Execute command
- [ ] Apply edit requests
- [ ] Workspace folders
- [ ] Workspace configuration
- [ ] Watched files
- [ ] Did-create files
- [ ] Will-create files
- [ ] Did-rename files
- [ ] Will-rename files
- [ ] Did-delete files
- [ ] Will-delete files

## Notebook Features

- [❌] Notebook document sync
- [❌] Notebook cell text-document mapping
- [❌] Notebook-aware diagnostics
- [❌] Notebook-aware semantic tokens

## Zitron-Aware Affordances

- [✅] Directive completions (no ⚡️)
- [✅] Grammar particle completions (no ⚡️)
- [✅] Rule action alias completions (no ⚡️)
- [✅] `%impl` alias completions (no ⚡️)
- [✅] Grammar symbol hover (no ⚡️)
- [✅] Generated Zig hover passthrough
- [✅] Grammar go-to-definition (no ⚡️)
- [✅] Generated Zig go-to-definition passthrough
- [✅] Grammar value-type definition navigation (no ⚡️)
- [✅] Generated Zig type-definition passthrough
- [✅] Same-document grammar references (no ⚡️)
- [✅] Generated Zig references passthrough
- [✅] Grammar terminal/generated token-enum references
- [✅] Grammar document symbols (no ⚡️)
- [✅] Generated Zig document symbols passthrough
- [✅] Zitron generator diagnostics (no ⚡️)
- [ ] Duplicate rule/action diagnostics
- [ ] Undefined rule/action diagnostics
- [ ] Unused rule/action diagnostics
- [ ] Precedence and associativity diagnostics
- [✅] Generated Zig compile diagnostics mapped back to `.zy`
- [✅] Action-body Zig diagnostics mapped back to `.zy`
- [ ] Cross-document grammar references
- [ ] Cross-document grammar symbols
- [ ] Include/import graph awareness
- [✅] Grammar rename refactoring (no ⚡️)
- [ ] Grammar extract action refactoring
- [ ] Grammar code actions for missing definitions
- [ ] Grammar code actions for unreachable productions
- [ ] Grammar formatting
- [ ] Grammar folding ranges
- [ ] Grammar semantic tokens
- [ ] Grammar selection ranges
- [✅] Grammar document highlights (no ⚡️)
- [✅] Grammar inlay hints (no ⚡️)
- [ ] Grammar signature help for directives
- [✅] Grammar signature help for named actions (no ⚡️)
- [ ] Rule call hierarchy
- [❌] Token/type hierarchy
- [ ] Parser conflict explanations
- [ ] Parser conflict navigation
- [ ] Railroad diagram document links
- [ ] Generated parser artifact links
- [ ] Generated Zig virtual document serving
- [ ] Source-to-generated Zig virtual document serving
- [ ] Generated-to-source location mapping API
- [ ] ZLS request forwarding beyond current passthroughs
