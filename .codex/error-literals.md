# Explicit Error Notes

## src/lsp_zitron.zig

- `loadFixtureAlloc -> FixtureError`
- `parseSource -> Error`
- `parseDocument -> Error`
- `Server.init -> ts.Query.Error`
- `Server.putDocument -> Error`
- `Server."textDocument/didOpen" -> Error`
- `Server."textDocument/didChange" -> Error`
- `Server."textDocument/hover" -> OOM`
- `hoverMarkdownForSymbol -> OOM`
- `byteIndexOf -> error{NeedleNotFound}`
- `byteIndexOfAfter -> error{NeedleNotFound}`
- `positionOfText -> error{NeedleNotFound}`
- `positionOfTextAfter -> error{NeedleNotFound}`

## src/main.zig

- `main -> zitron.Error || zitron.lsp.Transport.ReadError || zitron.lsp.Transport.WriteError`

## src/test_client.zig

- `main -> Error`
- `expectInitializeResponse -> Error`
- `expectHoverResponse -> Error`
- `expectDefinitionResponse -> Error`
- `expectNullResponse -> Error`
- `expectShutdownResponse -> Error`
- `byteIndexOf -> error{NeedleNotFound}`
- `byteIndexOfAfter -> error{NeedleNotFound}`
- `positionOfText -> error{NeedleNotFound}`
- `positionOfTextAfter -> error{NeedleNotFound}`
