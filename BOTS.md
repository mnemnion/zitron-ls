# AGENTS.md

This is a Zig-language LSP server for Zitron, an LALR(1) parser
generator for Zig code.

## Structure

We'll start simple and then get ambitious.  To begin with, we want
a basic integration of the Zitron tree-sitter:

- https://github.com/mnemnion/tree-sitter-zitron
- Zig bindings: https://github.com/tree-sitter/zig-tree-sitter

With an LSP:

- https://github.com/zigtools/lsp-kit/tree/0.15.x

Some example LSPs:

- https://github.com/zigtools/zls

- https://github.com/kristoff-it/superhtml

- https://github.com/kristoff-it/ziggy

First up is just getting everything functional. I have samples of the
syntax which we'll add early.

The longer-term plan is to also integrate zitron (for transforming grammars
as they're edited), and ZLS, so we can serve as a middleman to transfer
LSP requests back and forth from ZLS to the original source code, example:
go-to-definition within a grammar action.

## Server Capabilities Checklist

This list tracks what the server currently advertises.

- [✅] `positionEncoding`
- [✅] `textDocumentSync`
- [  ] `notebookDocumentSync`
- [  ] `completionProvider`
- [✅] `hoverProvider`
- [  ] `signatureHelpProvider`
- [  ] `declarationProvider`
- [✅] `definitionProvider`
- [  ] `typeDefinitionProvider`
- [  ] `implementationProvider`
- [✅] `referencesProvider`
- [  ] `documentHighlightProvider`
- [  ] `documentSymbolProvider`
- [  ] `codeActionProvider`
- [  ] `codeLensProvider`
- [  ] `documentLinkProvider`
- [  ] `colorProvider`
- [  ] `workspaceSymbolProvider`
- [  ] `documentFormattingProvider`
- [  ] `documentRangeFormattingProvider`
- [  ] `documentOnTypeFormattingProvider`
- [  ] `renameProvider`
- [  ] `foldingRangeProvider`
- [  ] `selectionRangeProvider`
- [  ] `executeCommandProvider`
- [  ] `callHierarchyProvider`
- [  ] `linkedEditingRangeProvider`
- [  ] `semanticTokensProvider`
- [  ] `monikerProvider`
- [  ] `typeHierarchyProvider`
- [  ] `inlineValueProvider`
- [  ] `inlayHintProvider`
- [  ] `diagnosticProvider`
- [  ] `inlineCompletionProvider`
- [  ] `workspace`
- [  ] `workspace.workspaceFolders`
- [  ] `workspace.fileOperations`
- [  ] `experimental`

## Pre-Commit

Before committing in this repo, run:

- `zig fmt` on each touched Zig file
- `zig build test smoke run-client`

Until otherwise directed, do not run:

  - `zig build coverage`

The other `zig build` commands are not relevant to pre-commit, consider
`coverage` stubbed out.

## Future Work

- Maintain a proper data structure for tracking line offsets, so LSP
  change processing and tree-sitter edit conversion do not need to
  rescan the document prefix for each change.
