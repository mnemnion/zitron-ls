# Generation Snapshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make ZLS diagnostic translation operate through published generation snapshots instead of mutable document state.

**Architecture:** Introduce a live `DocumentState` that owns the current published `GeneratedDocument` generation. `GeneratedDocument` becomes a snapshot with duplicated source text, generated text, code map, diagnostics, and a generation id. A document mutex guards live document table access and generation publication; translation paths use per-operation caches so published generations have no mutable translator cache.
`version = null` diagnostics are accepted only when no generation is in flight, exactly one generated sync has been sent, and the current generation is the one last sent to ZLS.

**Tech Stack:** Zig 0.16.0, `std.StringHashMapUnmanaged`, `std.Io.Mutex`, existing inline Zig tests in `src/ZigMiddleware.zig`.

---

## File Structure

- Modify `src/ZigMiddleware.zig`
  - Add `DocumentState`, `GenerationLookup`, and helper methods beside `GeneratedDocument`.
  - Change `Middleware.documents` from `GeneratedDocument` values to `DocumentState` values.
  - Refactor sync, close, diagnostics, and request lookup paths to go through `state.current`.
  - Add unit tests for generation lookup and lapped diagnostics.
- Modify `src/lsp_zitron.zig`
  - Copy merged diagnostics through a middleware helper while the generation is locked.
- Create `docs/superpowers/plans/2026-05-30-generation-snapshots.md`
  - Track this implementation.

## Task 1: Snapshot Types And Lookup Tests

**Files:**
- Modify: `src/ZigMiddleware.zig`

- [x] **Step 1: Write failing lookup tests**

Add tests near the existing middleware diagnostics tests:

```zig
test "document state resolves current generation by version" {
    var state = try makeTestDocumentState(testing_allocator, "file:///source.zy", 1, "source", "generated");
    defer state.deinit(testing_allocator);

    try expect(state.currentForVersion(1) != null);
    try expect(state.currentForVersion(2) == null);
}

test "document state rejects version-null diagnostics while generation is in flight" {
    var state = try makeTestDocumentState(testing_allocator, "file:///source.zy", 1, "source", "generated");
    defer state.deinit(testing_allocator);

    state.in_flight_version = 2;
    try expect(state.currentForVersion(null) == null);
}
```

- [x] **Step 2: Run red test**

Run: `zig build test -- --test-filter "document state"`

Expected: fail because `DocumentState`, `makeTestDocumentState`, or lookup helpers do not exist.

- [x] **Step 3: Implement minimal snapshot types**

Add these fields and helpers:

```zig
const DocumentState = struct {
    current: ?GeneratedDocument,
    latest_requested_version: i32,
    in_flight_version: ?i32,
    opened: bool,

    fn currentForVersion(state: *DocumentState, version: ?i32) ?*GeneratedDocument {
        const generation = &(state.current orelse return null);
        if (version) |value| {
            if (generation.version != value) return null;
        } else if (state.in_flight_version != null) {
            return null;
        }
        return generation;
    }

    fn deinit(state: *DocumentState, allocator: std.mem.Allocator) void {
        if (state.current) |*generation| generation.deinit(allocator);
    }
};
```

Update `GeneratedDocument.deinit` so it frees duplicated `source_text`.

- [x] **Step 4: Run green test**

Run: `zig build test -- --test-filter "document state"`

Expected: pass.

## Task 2: Publish Generations From Sync

**Files:**
- Modify: `src/ZigMiddleware.zig`

- [x] **Step 1: Write failing stale-publish test**

Add a helper-level test that simulates lapping without spawning `zitron`:

```zig
test "document state does not publish stale generation" {
    var state = DocumentState{
        .current = null,
        .latest_requested_version = 2,
        .in_flight_version = 1,
        .opened = false,
    };
    defer state.deinit(testing_allocator);

    var stale = try makeTestGeneratedDocument(testing_allocator, "file:///source.zy", 1, "old", "old generated");
    errdefer stale.deinit(testing_allocator);

    const published = try state.publishIfCurrent(testing_allocator, stale);
    try expect(!published);
    try expect(state.current == null);
}
```

- [x] **Step 2: Run red test**

Run: `zig build test -- --test-filter "publish stale generation"`

Expected: fail because `publishIfCurrent` does not exist.

- [x] **Step 3: Implement publication helper**

Add `DocumentState.publishIfCurrent`:

```zig
fn publishIfCurrent(
    state: *DocumentState,
    allocator: std.mem.Allocator,
    generation: GeneratedDocument,
) !bool {
    if (generation.version != state.latest_requested_version) {
        var stale = generation;
        stale.deinit(allocator);
        return false;
    }
    if (state.current) |*old| old.deinit(allocator);
    state.current = generation;
    state.in_flight_version = null;
    return true;
}
```

- [x] **Step 4: Refactor `middlewareSyncDocument`**

Change sync to:

1. get/create `DocumentState`;
2. set `latest_requested_version` and `in_flight_version`;
3. build a temporary `GeneratedDocument`;
4. publish only through `publishIfCurrent`;
5. send ZLS open/change only for the published generation.

- [x] **Step 5: Run tests**

Run: `zig build test -- --test-filter "publish stale generation"`

Expected: pass.

## Task 3: Diagnostic Translation Uses Generation Handles

**Files:**
- Modify: `src/ZigMiddleware.zig`

- [x] **Step 1: Write failing stale-diagnostics test**

Add a test using two versions of a document state:

```zig
test "ZLS diagnostics for stale generation do not replace current diagnostics" {
    var state = try makeTestDocumentState(testing_allocator, "file:///source.zy", 2, "source", "generated");
    defer state.deinit(testing_allocator);

    try expect(state.currentForVersion(1) == null);
}
```

- [x] **Step 2: Run red test**

Run: `zig build test -- --test-filter "stale generation"`

Expected: fail until document-state helpers are wired to diagnostics paths.

- [x] **Step 3: Refactor diagnostics path**

Change `middlewareHandleZlsDiagnostics` to:

1. lock `documents_mutex`;
2. resolve `DocumentState` by generated URI;
3. call `state.currentForVersion(params.version)`;
4. drop and log if no generation resolves;
5. translate through the resolved `GeneratedDocument`;
6. store diagnostics only if the generation is still `state.current`.

- [x] **Step 4: Run green test**

Run: `zig build test -- --test-filter "stale generation"`

Expected: pass.

## Task 4: Guard Live Document State

**Files:**
- Modify: `src/ZigMiddleware.zig`

- [x] **Step 1: Add `documents_mutex` to `Middleware`**

Add:

```zig
documents_mutex: std.Io.Mutex,
```

Initialize it with `.init` wherever `Middleware` is constructed.

- [x] **Step 2: Guard state access**

Lock around:

- `appendDiagnostics`
- `middlewareSyncDocument` state lookup and publish points
- `middlewareHandleZlsDiagnostics`
- `middlewareCloseDocument`
- `middlewareDeinit` document freeing
- `middlewareDocumentReady`
- `middlewareDocumentForGeneratedUri`

- [x] **Step 3: Run full tests**

Run: `zig build test`

Expected: pass.

## Task 5: Format And Smoke

**Files:**
- Modify: `src/ZigMiddleware.zig`

- [x] **Step 1: Format touched Zig file**

Run: `zig fmt src/ZigMiddleware.zig`

Expected: no errors.

- [x] **Step 2: Run full verification**

Run: `zig build test`

Expected: pass.

- [x] **Step 3: Review diff**

Run: `git diff -- src/ZigMiddleware.zig docs/superpowers/plans/2026-05-30-generation-snapshots.md`

Expected: diff only includes generation snapshot implementation and this plan.
