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

## Tree-Sitter

If tree-sitter is not doing what it ought to, DO NOT work around that
with elaborate server-side code.  Stop what you're doing and tell Sam
what's going on, because the fix probably belongs on the tree-sitter
parser side.
