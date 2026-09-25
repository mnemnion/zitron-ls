# Zitron Language Server


This is an [LSP] server for the [Zitron] grammar language.

Working with the [YACC] family can feel like a trip back in time, when
the warm glow of a hardware TTY came in one (1) color.  Not with Zitron.
We have [syntax highlighting][ts-zitron] through tree-sitter, for both
the grammar and the Zig code it quotes.  Already a step in the right
direction!

Now we have the rest of what the modern (spoiled rotten) developer looks
for in a sophisticated grammar DSL:

- [⚡️] Go to definition
- [⚡️] Go to reference
- [⚡️] Hover
- [⚡️] Rename
- [⚡️] Completions
- [⚡️] Inlay hints
- [⚡️] Semantic Tokens
- [⚡️] Diagnostics
- [⚡️] Formatting

Oh, and they work for the grammar, and the Zig code as well.
`zitron-ls` embeds the entirety of ZLS, and does a lot of [diffing].

Nice right?  We deserve nice things.

[diffing]: https://github.com/mnemnion/muad-diff


## Installation

This is early days: a certain amount of manual labor is involved in
getting `zitron-ls` stood up.


### Prerequisites

- Zig 0.16.x
- `zitron` on the `$PATH`: `zitron -v` should say at least `0.3.0`.


### Build

Straightforward enough, I would hope: clone the repo and `zig build`.
`-Doptimize=ReleaseSafe` is suggested.


### Use

If you follow the recommended pattern in the [zitron docs][zdoc],
which is to name your parser `zomething.zy` and arrange the rest of
the directory exactly as though it were named `zomething.zig`, then our
onboard ZLS will even be able to find go-to-reference into those files
as well.

[zdoc]: https://github.com/mnemnion/zitron/blob/trunk/doc/zitron.md#34-building-and-using-the-zitron-executable-


### Integrate

If you use Neovim, you're in luck: so do I, and I can show you how to
get this stood up accordingly.  This is [Lazy]-flavored setup code, for
the record.

#### Neovim

Drop this (with the obvious alterations) into the `lsp-mason` section of
your `init.lua`:

```lua
      {
        'williamboman/mason.nvim',
        init = function()
          vim.opt.rtp:append '/path/to/zitron-ls/registry'
        end,
        opts = {
          PATH = 'append',
          registries = {
            'file:/path/to/zitron-ls/registry/',
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
            cmd = { '/path/to/zitron-ls/zig-out/bin/zitron-ls' },
            filetypes = { 'zitron' },
            root_dir = function(fname)
              return util.root_pattern('build.zig', '.git')(fname) or vim.fs.dirname(fname)
            end,
            single_file_support = true,
          },
        }
      end
```

Reminder: typing `zitron -h` should do useful things: `zitron-ls` is
not expected to crash out if this doesn't work, but nor will it do many
cool things it otherwise would.

Make sure `zitron -v` is at least `v0.3.0` for best results.

Syntax highlighting comes from the [tree-sitter][ts-zitron], not
the LSP, so check out the instructions there to make things nice and
colorful.  We do provide "semantic tokens", but this is engineered to
supplement the tree-sitter rather than to replace it.

#### Any Editor Not Truly Esoteric

Realistically: you can ask a clanker to hook you up, and it will.

#### Any Editor Truly Esoteric

Y'all are used to figuring things out on your own.  You'll be fine.


### Did It Work?

There are a couple sample files in the `/samples` directory, they should
be colorful, and language server stuff should happen.  At least one
more-complete project (the EDN parser) is in [zitron-examples], which
shows that, in fact, `zls` can find references and imports in your Zig
code, assuming your build file colors within the lines as described in
the Zitron docs.

There's also [pikchresque], a port of [Pikchr] with a few bells and
whistles.  This is the whetstone against which the blade of this
language server was sharpened.

## Bugs

Renaming a type will not change its mention in a `%type` directive,
nor vice-versa.  There's probably a way to make this work, but I haven't
figured out what that is yet.

[LSP]: https://microsoft.github.io/language-server-protocol/
[zitron]: https://github.com/mnemnion/zitron
[yacc]: https://en.wikipedia.org/wiki/Yacc
[ts-zitron]: https://github.com/mnemnion/tree-sitter-zitron
[lazy]: https://github.com/folke/lazy.nvim
[zls]: https://github.com/zigtools/zls
[zitron-examples]: https://github.com/mnemnion/zitron-examples/
[pikchresque]: https://github.com/mnemnion/pikchresque
[Pikchr]: https://pikchr.org/home/doc/trunk/homepage.md
