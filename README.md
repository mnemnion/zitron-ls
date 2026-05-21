# Zitron Language Server


This is an [LSP] server for the [Zitron] grammar language.  Working with
the [YACC] family can feel like a trip back in time, when the warm glow
of a hardward TTY came in one (1) color.

Not with Zitron.  We have [syntax highlighting][ts-zitron] through tree-
sitter, for both the grammar and the Zig code it quotes.  Already a step
in the right direction!

Now we have the rest of what the modern (spoiled rotten) developer looks
for in a sophisticated grammar DSL:

- [⚡️] Go to definition
- [⚡️] Go to reference
- [⚡️] Hover
- [⚡️] Rename
- [⚡️] Completions
- [⚡️] Inlay hints

Oh, and they work for the grammar, and the Zig code[^1] as well.

Nice right?


## Installation

This is early days: a certain amount of manual labor is involved in
getting `lsp_zitron` stood up.


### Prerequisites

- Zig 0.16.x
- `zls` and `zitron` on the $PATH


### Build

Straightforward enough, I would hope: clone the repo and `zig build`.
`-Doptimize=ReleaseSafe` is suggested.


### Integrate

If you use Neovim, you're in luck: so do I, and I can show you how to
get this stood up accordingly.  This is [Lazy]-flavored setup code,
for the record.

Drop this into the `lsp-mason` section of your `init.lua`:

```lua
      {
        'williamboman/mason.nvim',
        init = function()
          vim.opt.rtp:append '/path/to/lsp_zitron/registry'
        end,
        opts = {
          PATH = 'append',
          registries = {
            'file:/path/to/lsp_zitron/registry/',
            'github:mason-org/mason-registry',
          },
        },
      },
```

With this block inside the `config` function of `neovim/nvim-lspconfig`:

```lua
      if not configs.lsp_zitron then
        configs.lsp_zitron = {
          default_config = {
            cmd = { '/path/to/lsp_zitron/zig-out/bin/lsp_zitron' },
            filetypes = { 'zitron' },
            root_dir = function(fname)
              return util.root_pattern('build.zig', '.git')(fname) or vim.fs.dirname(fname)
            end,
            single_file_support = true,
          },
        }
      end
```

Reminder: typing `zitron -h` and `zls -h` should do useful things:
`lsp_zitron` is not expected to crash out if this doesn't work, but nor
will it do many cool things it otherwise would.

Make sure `zitron -v` is at least `v0.2.2` for best results.

Syntax highlighting comes from the [tree-sitter][ts-zitron], not
the LSP, so check out the instructions there to make things nice and
colorful.


### Any Editor Not Truly Esoteric

Realistically you can ask a clanker to hook you up, and it will.


#### Any Editor Truly Esoteric

Y'all are used to figuring things out on your own.  You'll be fine.


### Did It Work?

There are a couple sample files in the `/samples` directory, they
should be colorful, and language server stuff should happen.  At least
one more-complete project (the EDN parser) is in [zitron-examples],
which shows that, in fact, `zls` can find references and imports in your
Zig code, assuming your build file colors within the lines as described
in the Zitron docs.


## Bugs

Renaming a type will not change its mention in a `%type` directive,
nor vice-versa.  There's probably a way to make this work, but I haven't
figured  out what that is yet.

[^1]: Offer only valid with [ZLS] installed.  Terms and conditions
apply.  `lsp_zitron` comes with NO WARRANTY

[LSP]: https://microsoft.github.io/language-server-protocol/
[zitron]: https://github.com/mnemnion/zitron
[yacc]: https://en.wikipedia.org/wiki/Yacc
[ts-zitron]: https://github.com/mnemnion/tree-sitter-zitron
[lazy]: https://github.com/folke/lazy.nvim
[zls]: https://github.com/zigtools/zls
[zitron-examples]: https://github.com/mnemnion/zitron-examples/
