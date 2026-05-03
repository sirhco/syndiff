# SynDiff Review Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--review` (alias `--format review-json`) NDJSON output to `syndiff` that emits an enriched, versioned (`review-v1`) stream consumable by an LLM-based review agent. Existing `--format json|yaml` output remains byte-identical (zero regression).

**Architecture:** Run existing `parse → diff → suppressCascade → sortByLocation → filter` pipeline, then layer enrichment passes (each independent and skippable for tests) before a new NDJSON renderer in `src/review.zig`. `Change` struct stays unmodified; enrichment data lives in a sidecar `ChangeMeta` parallel array allocated by the orchestrator. Two new `Node` columns (`identity_range_hash: u64`, `is_exported: bool`) populated by parsers on decl nodes.

**Tech Stack:** Zig 0.16+, `std.MultiArrayList`, `std.hash.Wyhash` (existing), `std.Io.Writer`. No new external deps.

**Conventions established by this codebase (read before coding):**
- Tests live in the same `.zig` file as production code under a `// Tests` separator; run via `zig build test`.
- Diff `Change` is a tagged union (`{kind, a_idx, b_idx}`); enrichment goes alongside, not inside.
- Renderers consume `*const DiffSet` via `std.Io.Writer`; never allocate during render.
- `std.MultiArrayList(Node)` keeps each field as a packed column; a new column is a one-line struct change but touches every parser's `addNode` call site.
- All parsers follow the pattern in `src/go_parser.zig:475` — `tree.addNode(.{...})` with named-field initializer.

**User constraint: do NOT include commit steps. The user will commit manually after reviewing.**

---

## Phase 0 — Foundation

Sets up the workspace, regression guards, and shared scaffolding before any AST changes.

### Task 0.1: Create isolated worktree

**Files:**
- Worktree path: `../syndiff-review-mode` (sibling of repo root)

- [ ] **Step 1: Create worktree on new branch**

```bash
cd /Users/chrisolson/development/github/syndiff
git worktree add -b feat/review-mode ../syndiff-review-mode main
cd ../syndiff-review-mode
```

- [ ] **Step 2: Verify clean state**

Run: `git status && git log --oneline -5`
Expected: clean tree, branch `feat/review-mode` at commit `946ec60`.

- [ ] **Step 3: Verify baseline tests pass**

Run: `zig build test`
Expected: all tests pass, exit code 0.

---

### Task 0.2: Snapshot test harness for review NDJSON

**Files:**
- Create: `testdata/review/.gitkeep`
- Create: `tests/review_snapshots.zig`
- Modify: `build.zig` (add review snapshot test step)

The harness reads `testdata/review/<case>/{a.<ext>,b.<ext>,expected.ndjson}`, runs the orchestrator on `(a, b)`, and asserts the produced NDJSON matches `expected.ndjson` byte-for-byte. Used by Phases 1–3 for end-to-end fixtures.

- [ ] **Step 1: Write the failing test scaffold**

Create `tests/review_snapshots.zig`:

```zig
//! End-to-end snapshot tests for `syndiff --review` output.
//!
//! Each subdirectory under `testdata/review/<case>/` is a fixture pair plus
//! `expected.ndjson`. The test parses both files, runs the review orchestrator,
//! and compares the rendered NDJSON against `expected.ndjson` byte-for-byte.

const std = @import("std");
const syndiff = @import("syndiff");
const review = @import("syndiff").review;

fn runCase(gpa: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var a_path: ?[]u8 = null;
    var b_path: ?[]u8 = null;
    defer if (a_path) |p| gpa.free(p);
    defer if (b_path) |p| gpa.free(p);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, "a.")) {
            a_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.name });
        } else if (std.mem.startsWith(u8, entry.name, "b.")) {
            b_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.name });
        }
    }
    const a = a_path orelse return error.MissingA;
    const b = b_path orelse return error.MissingB;

    const expected = try std.fs.cwd().readFileAlloc(
        gpa,
        try std.fmt.allocPrint(gpa, "{s}/expected.ndjson", .{dir_path}),
        1 << 20,
    );
    defer gpa.free(expected);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var w = std.Io.Writer.fromArrayList(gpa, &buf);
    try review.runFilePair(gpa, a, b, &w);

    try std.testing.expectEqualStrings(expected, buf.items);
}

test "review snapshot: placeholder (will be populated in Phase 1)" {
    // Real cases added in tasks 1.7+. This test ensures the harness compiles.
    return error.SkipZigTest;
}
```

- [ ] **Step 2: Run; expect compile error**

Run: `zig build test`
Expected: FAIL — `review.runFilePair` does not exist yet (will be created in Task 1.5). This proves the harness is wired into the build.

- [ ] **Step 3: Wire into build.zig**

Open `build.zig` and locate the `mod_tests` / `exe_tests` declarations (around line 145–160). Add a third test executable that compiles `tests/review_snapshots.zig`:

```zig
const review_snap_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/review_snapshots.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "syndiff", .module = mod },
        },
    }),
});
const run_review_snap = b.addRunArtifact(review_snap_tests);
test_step.dependOn(&run_review_snap.step);
```

- [ ] **Step 4: Verify**

Run: `zig build test 2>&1 | head -40`
Expected: compile error referencing `review.runFilePair`. Comment out the `try review.runFilePair(...)` line and the test should compile and skip.

---

### Task 0.3: Golden regression fixtures for `--format json` and `--format yaml`

**Files:**
- Create: `testdata/golden/json_modified.golden`
- Create: `testdata/golden/yaml_modified.golden`
- Create: `tests/golden_regression.zig`
- Modify: `build.zig` (add golden regression test step)

Captures current `--format json|yaml` output for representative inputs. Phase 1's Node struct change must not alter these bytes.

- [ ] **Step 1: Generate golden output**

Run from the worktree root:

```bash
mkdir -p testdata/golden
cat > /tmp/a.json <<'EOF'
{"name":"alice","age":30}
EOF
cat > /tmp/b.json <<'EOF'
{"name":"alice","age":31,"new_field":true}
EOF
zig build run -- --files /tmp/a.json /tmp/b.json --format json --no-color > testdata/golden/json_modified.golden
zig build run -- --files /tmp/a.json /tmp/b.json --format yaml --no-color > testdata/golden/yaml_modified.golden
```

- [ ] **Step 2: Verify goldens are non-empty and contain expected fields**

Run: `wc -l testdata/golden/*.golden && grep -c '"kind"' testdata/golden/json_modified.golden`
Expected: each file has ≥1 line, json file has ≥2 occurrences of `"kind"`.

- [ ] **Step 3: Write the regression test**

Create `tests/golden_regression.zig`:

```zig
//! Asserts `--format json|yaml` output is byte-identical to checked-in goldens.
//!
//! The review-mode pipeline added new `Node` columns and parsers; this guards
//! against any regression that bleeds through into the existing renderers.

const std = @import("std");
const syndiff = @import("syndiff");

fn diffPairToString(
    gpa: std.mem.Allocator,
    a_src: []const u8,
    b_src: []const u8,
    out: *std.ArrayList(u8),
    format: enum { json, yaml },
) !void {
    var a = try syndiff.json_parser.parse(gpa, a_src, "/tmp/a.json");
    defer a.deinit();
    var b = try syndiff.json_parser.parse(gpa, b_src, "/tmp/b.json");
    defer b.deinit();

    var set = try syndiff.differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try syndiff.differ.suppressCascade(&set, &a, &b, gpa);
    syndiff.differ.sortByLocation(&set, &a, &b);

    var w = std.Io.Writer.fromArrayList(gpa, out);
    switch (format) {
        .json => try syndiff.differ.renderJson(&set, &a, &b, &w),
        .yaml => try syndiff.differ.renderYaml(&set, &a, &b, &w),
    }
}

test "golden: json output for modified+added fields is byte-stable" {
    const gpa = std.testing.allocator;
    const a = "{\"name\":\"alice\",\"age\":30}\n";
    const b = "{\"name\":\"alice\",\"age\":31,\"new_field\":true}\n";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try diffPairToString(gpa, a, b, &buf, .json);

    const golden = try std.fs.cwd().readFileAlloc(gpa, "testdata/golden/json_modified.golden", 1 << 16);
    defer gpa.free(golden);

    try std.testing.expectEqualStrings(golden, buf.items);
}

test "golden: yaml output for modified+added fields is byte-stable" {
    const gpa = std.testing.allocator;
    const a = "{\"name\":\"alice\",\"age\":30}\n";
    const b = "{\"name\":\"alice\",\"age\":31,\"new_field\":true}\n";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try diffPairToString(gpa, a, b, &buf, .yaml);

    const golden = try std.fs.cwd().readFileAlloc(gpa, "testdata/golden/yaml_modified.golden", 1 << 16);
    defer gpa.free(golden);

    try std.testing.expectEqualStrings(golden, buf.items);
}
```

- [ ] **Step 4: Wire into build.zig**

In the same block where `review_snap_tests` was added, add `golden_tests` with `tests/golden_regression.zig` and add `b.addRunArtifact(golden_tests).step` to `test_step.dependOn`.

- [ ] **Step 5: Verify**

Run: `zig build test`
Expected: all tests pass, including the two new golden tests.

---

## Phase 1 — Tier 1: Schema Enrichment

Adds new Node columns, `Change` sidecar metadata, the `--review` CLI flag, the `src/review.zig` orchestrator + renderer, and snapshot fixtures for `kind_tag` and basic counts.

### Task 1.1: Add `identity_range_hash` and `is_exported` columns to Node

**Files:**
- Modify: `src/ast.zig:100-108` (Node struct)
- Modify: `src/ast.zig:194-204` (test helper `makeNode`)

`identity_range_hash` is the Wyhash of `source[identity_range.start..identity_range.end]`. It exists so review mode can detect signature changes (identity bytes differ) vs body changes (only subtree hash differs) without re-reading source. `is_exported` is per-language visibility.

- [ ] **Step 1: Write failing test for new Node fields**

Add to `src/ast.zig` after the `MultiArrayList SoA layout` test (around line 343):

```zig
test "Node carries identity_range_hash and is_exported columns" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa, "", "");
    defer tree.deinit();

    var n = makeNode(.go_fn, ROOT_PARENT);
    n.identity_range_hash = 0xCAFEF00DCAFEF00D;
    n.is_exported = true;
    _ = try tree.addNode(n);

    const irhs: []u64 = tree.nodes.items(.identity_range_hash);
    const exps: []bool = tree.nodes.items(.is_exported);
    try std.testing.expectEqual(@as(u64, 0xCAFEF00DCAFEF00D), irhs[0]);
    try std.testing.expectEqual(true, exps[0]);
}
```

- [ ] **Step 2: Run test; expect compile error**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL with `no field named 'identity_range_hash' in struct 'ast.Node'`.

- [ ] **Step 3: Add fields to Node**

Edit `src/ast.zig:100-108`:

```zig
pub const Node = struct {
    hash: u64,
    identity_hash: u64,
    identity_range_hash: u64,
    kind: Kind,
    depth: u16,
    parent_idx: NodeIndex,
    content_range: Range,
    identity_range: Range,
    is_exported: bool,
};
```

- [ ] **Step 4: Update test helper**

Edit `src/ast.zig:194-204` (`makeNode`):

```zig
fn makeNode(kind: Kind, parent: NodeIndex) Node {
    return .{
        .hash = 0,
        .identity_hash = 0,
        .identity_range_hash = 0,
        .kind = kind,
        .depth = 0,
        .parent_idx = parent,
        .content_range = Range.empty,
        .identity_range = Range.empty,
        .is_exported = false,
    };
}
```

- [ ] **Step 5: Run; expect every parser to fail compilation**

Run: `zig build test 2>&1 | head -50`
Expected: FAIL with "missing field" errors in every `*_parser.zig` `addNode` call site. This is the work for Task 1.2.

---

### Task 1.2: Update every parser's `addNode` call sites

**Files:**
- Modify: `src/json_parser.zig`, `src/yaml_parser.zig`, `src/rust_parser.zig`, `src/go_parser.zig`, `src/zig_parser.zig`, `src/dart_parser.zig`, `src/js_parser.zig`, `src/ts_parser.zig`

Strategy: every existing `addNode(.{...})` initializer must add both new fields. For Phase 1, set `identity_range_hash = 0` and `is_exported = false` in every site. Real values come in tasks 1.3 (`identity_range_hash`) and 1.4 (`is_exported`). This task only restores compilation.

- [ ] **Step 1: List every addNode site**

Run: `grep -n "tree.addNode(.{" src/*_parser.zig | wc -l`
Record: there are roughly 30+ sites. Visit each with `grep -n "tree.addNode(.{" src/<file>` and add the two new initializer lines.

- [ ] **Step 2: For each parser, add `identity_range_hash = 0` and `is_exported = false`**

Example diff for `src/go_parser.zig:475-483`:

```zig
const fn_idx = try self.tree.addNode(.{
    .hash = fn_h,
    .identity_hash = fn_identity,
    .identity_range_hash = 0,
    .kind = kind,
    .depth = 1,
    .parent_idx = ROOT_PARENT,
    .content_range = .{ .start = decl_start, .end = decl_end },
    .identity_range = ident_range,
    .is_exported = false,
});
```

Apply the analogous change to **every** `addNode(.{...})` literal in:
- `src/json_parser.zig` — all members, scalars, root
- `src/yaml_parser.zig` — pairs, scalars, mappings, root
- `src/rust_parser.zig` — fn, struct, impl, trait, mod, use, const, macro, stmt, root
- `src/go_parser.zig` — package, import, fn, method, type, var, const, stmt, root
- `src/zig_parser.zig` — fn, decl, struct, stmt, root
- `src/dart_parser.zig` — class, mixin, enum, extension, typedef, fn, method, field, const, import, stmt, root
- `src/js_parser.zig` — function, class, method, const, let, var, import, export, stmt, root
- `src/ts_parser.zig` — interface, type, enum, namespace, declare, stmt, plus all JS-mirrored kinds

Don't try to be clever and skip "synthetic" or "anonymous" nodes; they all go through `addNode`.

- [ ] **Step 3: Run; expect green**

Run: `zig build test`
Expected: all tests pass, including the new `Node carries identity_range_hash and is_exported columns` test.

- [ ] **Step 4: Verify goldens still pass**

Run: `zig build test 2>&1 | grep -i golden`
Expected: both golden tests pass — Node bytes grew but the renderers don't read the new columns yet.

---

### Task 1.3: Populate `identity_range_hash` in parsers

**Files:**
- Create: `src/ast.zig` — add helper `computeIdentityRangeHash`
- Modify: every `*_parser.zig` `addNode(.{...})` site for **decl-bearing kinds only** (not `*_stmt`, not `file_root`, not container-only nodes like `json_object`/`yaml_mapping`/`rust_impl`)

For decl nodes (`go_fn`, `go_method`, `go_type`, `rust_fn`, `rust_struct`, ..., `dart_class`, `js_function`, `ts_interface`, etc.), set `identity_range_hash = std.hash.Wyhash.hash(0, source[identity_range.start..identity_range.end])`. For all other nodes, leave it `0`.

- [ ] **Step 1: Write failing test**

Add to `src/ast.zig` test block:

```zig
test "identity_range_hash equals Wyhash of identity bytes" {
    const gpa = std.testing.allocator;
    const src = "fn foo() {}";
    var tree = Tree.init(gpa, src, "x.zig");
    defer tree.deinit();

    var n = makeNode(.zig_fn, ROOT_PARENT);
    n.identity_range = .{ .start = 3, .end = 6 }; // "foo"
    n.identity_range_hash = std.hash.Wyhash.hash(0, "foo");
    _ = try tree.addNode(n);

    const irhs = tree.nodes.items(.identity_range_hash);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, "foo"), irhs[0]);
}
```

(Trivial test, but locks in the hash convention so all parsers stay consistent.)

- [ ] **Step 2: Run test; expect pass**

Run: `zig build test`
Expected: PASS — the test only validates the convention, no parser change yet.

- [ ] **Step 3: Update Go parser's fn/method/type/var/const sites**

For `src/go_parser.zig:475` (`fn_idx` site) and the other decl sites (use `grep -n "kind = .go_" src/go_parser.zig`):

```zig
const fn_idx = try self.tree.addNode(.{
    .hash = fn_h,
    .identity_hash = fn_identity,
    .identity_range_hash = std.hash.Wyhash.hash(0, name_bytes),
    .kind = kind,
    // ... rest unchanged
    .is_exported = false,
});
```

`name_bytes` is already in scope in the Go fn parser (line 435). For the helper `emitDecl` (line 622), use `ident_bytes`.

- [ ] **Step 4: Apply to Rust, Zig, Dart, JS, TS parsers**

Each parser already extracts the identity bytes (e.g., `ident_bytes`, `name_bytes`). Compute `identity_range_hash = std.hash.Wyhash.hash(0, <those bytes>)` at every decl-bearing `addNode`.

Pattern by parser:
- `src/rust_parser.zig` — `rust_fn`, `rust_struct`, `rust_impl`, `rust_trait`, `rust_mod`, `rust_const`, `rust_macro` (skip `rust_use`, `rust_stmt`)
- `src/zig_parser.zig` — `zig_fn`, `zig_decl`, `zig_struct` (skip `zig_stmt`)
- `src/dart_parser.zig` — `dart_class`, `dart_mixin`, `dart_enum`, `dart_extension`, `dart_typedef`, `dart_fn`, `dart_method`, `dart_field`, `dart_const` (skip `dart_import`, `dart_stmt`)
- `src/js_parser.zig` — `js_function`, `js_class`, `js_method`, `js_const`, `js_let`, `js_var` (skip `js_import`, `js_export`, `js_stmt`)
- `src/ts_parser.zig` — all `ts_*` and JS-mirrored kinds except stmt
- `src/json_parser.zig` — only `json_member` (use the member's key bytes); skip everything else
- `src/yaml_parser.zig` — only `yaml_pair` (key bytes); skip everything else

For nodes with empty `identity_range`, leave the hash at `0` (degenerate but fine).

- [ ] **Step 5: Verify**

Run: `zig build test`
Expected: PASS, no regressions in golden or existing parser tests.

---

### Task 1.4: Populate `is_exported` per language

**Files:**
- Modify: each `*_parser.zig` decl-bearing `addNode` site

Per-language rules (heuristic; review tool decides relevance):
- **Go**: `is_exported = identity_bytes.len > 0 and std.ascii.isUpper(identity_bytes[0])`
- **Rust**: `is_exported = source[content_range.start..content_range.end]` starts with `pub` (after trimming attrs/whitespace) — implement via a small `startsWithKeyword` helper
- **Zig**: same as Rust, looking for `pub`
- **Dart**: `is_exported = identity_bytes.len > 0 and identity_bytes[0] != '_'`
- **JS**: `is_exported = ` whether the decl was emitted under a `js_export` parent OR the source slice starts with `export` — pragmatic check: `std.mem.startsWith(u8, content_slice, "export")`
- **TS**: same as JS, plus `declare` counts as exported
- **JSON / YAML**: leave `false`

- [ ] **Step 1: Write failing tests, one per language**

Append to `src/go_parser.zig` test block:

```zig
test "is_exported true for capitalized Go fns" {
    const gpa = std.testing.allocator;
    var tree = try parse(gpa, "func Foo() {}\nfunc bar() {}\n", "x.go");
    defer tree.deinit();
    const kinds = tree.nodes.items(.kind);
    const exps = tree.nodes.items(.is_exported);
    var saw_pub = false;
    var saw_priv = false;
    for (kinds, exps, 0..) |k, exp, i| {
        if (k != .go_fn) continue;
        const name = tree.identitySlice(@intCast(i));
        if (std.mem.eql(u8, name, "Foo")) {
            try std.testing.expect(exp);
            saw_pub = true;
        } else if (std.mem.eql(u8, name, "bar")) {
            try std.testing.expect(!exp);
            saw_priv = true;
        }
    }
    try std.testing.expect(saw_pub and saw_priv);
}
```

Add analogous tests in `src/rust_parser.zig`, `src/zig_parser.zig`, `src/dart_parser.zig`, `src/js_parser.zig`, `src/ts_parser.zig`. Sample inputs:

| Lang | Exported sample | Private sample |
|------|----------------|----------------|
| Rust | `pub fn foo() {}` | `fn bar() {}` |
| Zig | `pub fn foo() void {}` | `fn bar() void {}` |
| Dart | `void publicFn() {}` | `void _privateFn() {}` |
| JS | `export function foo() {}` | `function bar() {}` |
| TS | `export interface Foo {}` | `interface Bar {}` |

- [ ] **Step 2: Run; expect failures (all `is_exported` currently false)**

Run: `zig build test 2>&1 | grep -A2 "expect.*saw_pub"`
Expected: FAIL — `is_exported` is `false` for capitalized/`pub`/`export` decls.

- [ ] **Step 3: Implement per-language rule**

For Go (`src/go_parser.zig:475`):

```zig
const is_exported = name_bytes.len > 0 and std.ascii.isUpper(name_bytes[0]);
const fn_idx = try self.tree.addNode(.{
    // ...existing fields...
    .is_exported = is_exported,
});
```

For Rust / Zig — add a helper that walks back from `decl_start` past whitespace/attrs and checks for the keyword `pub`:

```zig
fn startsWithVisibility(src: []const u8, start: u32, keyword: []const u8) bool {
    var i: usize = start;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') { i += 1; continue; }
        // skip attributes: `#[...]` (rust) or `@...` (zig has none, but harmless)
        if (c == '#' and i + 1 < src.len and src[i + 1] == '[') {
            while (i < src.len and src[i] != ']') i += 1;
            if (i < src.len) i += 1;
            continue;
        }
        break;
    }
    return std.mem.startsWith(u8, src[i..], keyword);
}
```

Use `startsWithVisibility(self.src, decl_start, "pub")` at each decl site in Rust and Zig parsers.

For Dart: `is_exported = name_bytes.len > 0 and name_bytes[0] != '_'`.

For JS / TS: `is_exported = std.mem.startsWith(u8, std.mem.trimLeft(u8, self.src[decl_start..], " \t\n\r"), "export") or std.mem.startsWith(u8, ..., "declare")` (TS only).

- [ ] **Step 4: Run; expect green**

Run: `zig build test`
Expected: all parser tests pass including new is_exported tests; goldens still pass.

---

### Task 1.5: Create `src/review.zig` — orchestrator + Tier 1 renderer

**Files:**
- Create: `src/review.zig`
- Modify: `src/root.zig` (re-export `review`)

The orchestrator owns the `ChangeMeta` sidecar array, invokes enrichment passes, and renders `review-v1` NDJSON. Phase 1 produces `schema`, per-change records (with `change_id`, `scope`, `kind_tag`, `is_exported`, `lines_added`, `lines_removed`), and a `summary` record.

- [ ] **Step 1: Write failing skeleton test**

Create `src/review.zig`:

```zig
//! Review-mode NDJSON pipeline.
//!
//! Wraps the existing `differ.diff → suppressCascade → sortByLocation → filter`
//! pipeline with enrichment passes and a `review-v1`-versioned NDJSON renderer.
//! Existing `differ.renderJson` / `differ.renderYaml` are untouched.

const std = @import("std");
const ast = @import("ast.zig");
const differ = @import("differ.zig");
const line_diff = @import("line_diff.zig");

pub const SCHEMA_VERSION = "review-v1";
pub const SYNDIFF_VERSION = "0.1.0";

/// Sidecar metadata parallel to `DiffSet.changes`. Index `i` of `metas`
/// corresponds to index `i` of `set.changes.items`.
pub const ChangeMeta = struct {
    change_id: u64 = 0,
    /// Dotted scope path (e.g. "pkg.Foo.bar"). Owned by orchestrator arena.
    scope: []const u8 = "",
    kind_tag: KindTag = .body_change,
    is_exported: bool = false,
    lines_added: u32 = 0,
    lines_removed: u32 = 0,
};

pub const KindTag = enum { signature_change, body_change, structural };

pub const Summary = struct {
    files_changed: u32 = 0,
    counts: struct { added: u32 = 0, deleted: u32 = 0, modified: u32 = 0, moved: u32 = 0 } = .{},
    exported_changes: u32 = 0,
};

test "review module compiles" {
    try std.testing.expect(SCHEMA_VERSION.len > 0);
}
```

- [ ] **Step 2: Add to `src/root.zig`**

```zig
pub const review = @import("review.zig");
```

And add `_ = review;` in the `test` block.

- [ ] **Step 3: Run; expect pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 4: Implement `runFilePair` (test entry point)**

Append to `src/review.zig`:

```zig
const json_parser = @import("json_parser.zig");
const yaml_parser = @import("yaml_parser.zig");
const rust_parser = @import("rust_parser.zig");
const go_parser = @import("go_parser.zig");
const zig_parser = @import("zig_parser.zig");
const dart_parser = @import("dart_parser.zig");
const js_parser = @import("js_parser.zig");
const ts_parser = @import("ts_parser.zig");

const Lang = enum { json, yaml, rust, go, zig, dart, js, ts, unknown };

fn langFromPath(path: []const u8) Lang {
    if (std.ascii.endsWithIgnoreCase(path, ".json")) return .json;
    if (std.ascii.endsWithIgnoreCase(path, ".yaml") or std.ascii.endsWithIgnoreCase(path, ".yml")) return .yaml;
    if (std.ascii.endsWithIgnoreCase(path, ".rs")) return .rust;
    if (std.ascii.endsWithIgnoreCase(path, ".go")) return .go;
    if (std.ascii.endsWithIgnoreCase(path, ".zig")) return .zig;
    if (std.ascii.endsWithIgnoreCase(path, ".dart")) return .dart;
    if (std.ascii.endsWithIgnoreCase(path, ".js") or std.ascii.endsWithIgnoreCase(path, ".mjs") or std.ascii.endsWithIgnoreCase(path, ".cjs")) return .js;
    if (std.ascii.endsWithIgnoreCase(path, ".ts") or std.ascii.endsWithIgnoreCase(path, ".tsx") or std.ascii.endsWithIgnoreCase(path, ".mts") or std.ascii.endsWithIgnoreCase(path, ".cts")) return .ts;
    return .unknown;
}

fn parseLang(gpa: std.mem.Allocator, src: []const u8, path: []const u8, lang: Lang) !ast.Tree {
    return switch (lang) {
        .json => json_parser.parse(gpa, src, path),
        .yaml => yaml_parser.parse(gpa, src, path),
        .rust => rust_parser.parse(gpa, src, path),
        .go => go_parser.parse(gpa, src, path),
        .zig => blk: {
            const z = try gpa.dupeZ(u8, src);
            break :blk zig_parser.parse(gpa, z, path);
        },
        .dart => dart_parser.parse(gpa, src, path),
        .js => js_parser.parse(gpa, src, path),
        .ts => ts_parser.parse(gpa, src, path),
        .unknown => error.UnsupportedLanguage,
    };
}

/// Test-friendly entry: read two files from disk, run the review pipeline,
/// emit NDJSON. The CLI uses `runDiffSet` directly.
pub fn runFilePair(
    gpa: std.mem.Allocator,
    a_path: []const u8,
    b_path: []const u8,
    writer: *std.Io.Writer,
) !void {
    const a_src = try std.fs.cwd().readFileAlloc(gpa, a_path, 1 << 28);
    defer gpa.free(a_src);
    const b_src = try std.fs.cwd().readFileAlloc(gpa, b_path, 1 << 28);
    defer gpa.free(b_src);

    const lang = langFromPath(a_path);
    var a = try parseLang(gpa, a_src, a_path, lang);
    defer a.deinit();
    var b = try parseLang(gpa, b_src, b_path, lang);
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);
    differ.sortByLocation(&set, &a, &b);

    try renderReviewJson(gpa, &set, &a, &b, writer);
}
```

- [ ] **Step 5: Implement `renderReviewJson` for Tier 1**

```zig
pub fn renderReviewJson(
    gpa: std.mem.Allocator,
    set: *differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    writer: *std.Io.Writer,
) !void {
    // Allocate sidecar.
    const metas = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer gpa.free(metas);
    for (metas) |*m| m.* = .{};

    try annotateScope(gpa, set, a, b, metas);
    try annotateKindTag(set, a, b, metas);
    annotateExport(set, a, b, metas);
    try annotateChangeId(set, a, b, metas);
    try annotateLineChurn(gpa, set, a, b, metas);

    var summary: Summary = .{};

    // Header.
    try writer.print("{{\"kind\":\"schema\",\"version\":\"{s}\",\"syndiff\":\"{s}\"}}\n", .{ SCHEMA_VERSION, SYNDIFF_VERSION });

    // Records.
    for (set.changes.items, metas) |c, m| {
        try writeRecord(writer, &c, &m, a, b);
        switch (c.kind) {
            .added => summary.counts.added += 1,
            .deleted => summary.counts.deleted += 1,
            .modified => summary.counts.modified += 1,
            .moved => summary.counts.moved += 1,
        }
        if (m.is_exported) summary.exported_changes += 1;
    }

    // Files-changed: union of `a.path` and `b.path`. For now `runFilePair` only
    // ever has one pair, so this is always 1. Multi-file driver will pass real
    // counts through `Summary` directly in Phase 2.
    summary.files_changed = 1;

    try writer.print(
        "{{\"kind\":\"summary\",\"files_changed\":{d},\"counts\":{{\"added\":{d},\"deleted\":{d},\"modified\":{d},\"moved\":{d}}},\"exported_changes\":{d}}}\n",
        .{ summary.files_changed, summary.counts.added, summary.counts.deleted, summary.counts.modified, summary.counts.moved, summary.exported_changes },
    );
}
```

`writeRecord`, `writeJsonString`, and the `annotate*` helpers come in tasks 1.6 a–e.

- [ ] **Step 6: Verify build still compiles**

Run: `zig build test 2>&1 | head -30`
Expected: compile errors for the missing `annotate*` and `writeRecord` symbols. This is expected; tasks 1.6 fill them in.

---

### Task 1.6: Implement enrichment passes

#### Task 1.6a: `annotateScope` (dotted path from parent chain)

- [ ] **Step 1: Test**

Add to `src/review.zig`:

```zig
test "annotateScope joins identity slices with '.'" {
    const gpa = std.testing.allocator;
    var a = try go_parser.parse(gpa, "package main\nfunc Foo() {}\n", "a.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo() { return }\n", "b.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);

    const metas = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer gpa.free(metas);
    for (metas) |*m| m.* = .{};
    try annotateScope(gpa, &set, &a, &b, metas);

    // At least one meta should have a non-empty scope ending in "Foo".
    var found = false;
    for (metas) |m| {
        if (std.mem.endsWith(u8, m.scope, "Foo")) found = true;
    }
    try std.testing.expect(found);
}
```

- [ ] **Step 2: Run; expect compile error (annotateScope undefined)**

Run: `zig build test 2>&1 | head -10`
Expected: FAIL.

- [ ] **Step 3: Implement**

```zig
/// Walk parent_idx chain backwards, collecting identity slices. Joins with '.'.
/// Allocates each scope string via `gpa`; orchestrator owns until end of run.
pub fn annotateScope(
    gpa: std.mem.Allocator,
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) !void {
    for (set.changes.items, metas) |c, *m| {
        const tree, const idx = if (c.b_idx) |bi|
            .{ b, bi }
        else
            .{ a, c.a_idx.? };

        var stack: std.ArrayList([]const u8) = .empty;
        defer stack.deinit(gpa);

        const parents = tree.nodes.items(.parent_idx);
        const ranges = tree.nodes.items(.identity_range);

        var cur: ast.NodeIndex = idx;
        while (cur != ast.ROOT_PARENT) {
            const r = ranges[cur];
            if (r.end > r.start) try stack.append(gpa, tree.source[r.start..r.end]);
            cur = parents[cur];
        }

        if (stack.items.len == 0) {
            m.scope = "";
            continue;
        }

        // Reverse and join with '.'.
        var total: usize = 0;
        for (stack.items) |s| total += s.len;
        total += stack.items.len - 1; // separators

        const buf = try gpa.alloc(u8, total);
        var w: usize = 0;
        var i: usize = stack.items.len;
        while (i > 0) {
            i -= 1;
            const s = stack.items[i];
            @memcpy(buf[w .. w + s.len], s);
            w += s.len;
            if (i > 0) {
                buf[w] = '.';
                w += 1;
            }
        }
        m.scope = buf;
    }
}
```

- [ ] **Step 4: Run; expect pass**

Run: `zig build test`
Expected: PASS.

#### Task 1.6b: `annotateKindTag`

- [ ] **Step 1: Test**

```zig
test "annotateKindTag: same identity bytes = body_change" {
    const gpa = std.testing.allocator;
    var a = try go_parser.parse(gpa, "package main\nfunc Foo() { return 1 }\n", "a.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo() { return 2 }\n", "b.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);

    const metas = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer gpa.free(metas);
    for (metas) |*m| m.* = .{};
    try annotateKindTag(&set, &a, &b, metas);

    const kinds_b = b.nodes.items(.kind);
    for (set.changes.items, metas) |c, m| {
        if (c.kind != .modified) continue;
        if (kinds_b[c.b_idx.?] == .go_fn) {
            try std.testing.expectEqual(KindTag.body_change, m.kind_tag);
        }
    }
}

test "annotateKindTag: different identity bytes = signature_change" {
    const gpa = std.testing.allocator;
    var a = try go_parser.parse(gpa, "package main\nfunc Foo(x int) {}\n", "a.go");
    defer a.deinit();
    // Note: renaming the param is technically a body change in our parser's
    // current granularity (params aren't broken into nodes). To force an
    // identity_range_hash difference at the fn level we need the same
    // identity_hash but different identity_range_hash — currently impossible
    // because identity_hash also folds in identity bytes. So this test
    // documents that today, signature_change comes from identity_range_hash
    // differing AT a node whose identity_hash matches — which only happens
    // if a future enhancement decouples the two. For now, the assertion is
    // that the tag is computed correctly given the underlying data.
    _ = b: {
        var dummy = try go_parser.parse(gpa, "package main\nfunc Foo(x int) {}\n", "b.go");
        break :b dummy;
    };
    // Test scaffolding only; real coverage for this comes in Phase 2 when
    // signature.zig adds Param-level hashes.
}
```

(The second test is intentionally a placeholder; signature change discrimination is meaningful only when Phase 2's `Signature.hash` is wired in. Phase 1 just sets the tag based on `identity_range_hash` equality, which today is rarely useful but is the structural hook.)

- [ ] **Step 2: Implement**

```zig
pub fn annotateKindTag(
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) !void {
    const a_irhs = a.nodes.items(.identity_range_hash);
    const b_irhs = b.nodes.items(.identity_range_hash);
    for (set.changes.items, metas) |c, *m| {
        m.kind_tag = switch (c.kind) {
            .modified => blk: {
                const ai = c.a_idx.?;
                const bi = c.b_idx.?;
                break :blk if (a_irhs[ai] != b_irhs[bi]) .signature_change else .body_change;
            },
            .added, .deleted, .moved => .structural,
        };
    }
}
```

- [ ] **Step 3: Run; expect pass**

Run: `zig build test`
Expected: PASS.

#### Task 1.6c: `annotateExport`

- [ ] **Step 1: Implement (no test needed beyond Task 1.4 coverage)**

```zig
pub fn annotateExport(
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) void {
    const a_exp = a.nodes.items(.is_exported);
    const b_exp = b.nodes.items(.is_exported);
    for (set.changes.items, metas) |c, *m| {
        m.is_exported = if (c.b_idx) |bi| b_exp[bi] else if (c.a_idx) |ai| a_exp[ai] else false;
    }
}
```

#### Task 1.6d: `annotateChangeId`

- [ ] **Step 1: Test**

```zig
test "annotateChangeId is stable across runs" {
    const gpa = std.testing.allocator;
    var a = try go_parser.parse(gpa, "package main\nfunc Foo() { return 1 }\n", "a.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo() { return 2 }\n", "b.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);

    const m1 = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer gpa.free(m1);
    for (m1) |*m| m.* = .{};
    try annotateChangeId(&set, &a, &b, m1);

    const m2 = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer gpa.free(m2);
    for (m2) |*m| m.* = .{};
    try annotateChangeId(&set, &a, &b, m2);

    for (m1, m2) |x, y| try std.testing.expectEqual(x.change_id, y.change_id);
}
```

- [ ] **Step 2: Implement**

```zig
pub fn annotateChangeId(
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) !void {
    const a_id = a.nodes.items(.identity_hash);
    const b_id = b.nodes.items(.identity_hash);
    for (set.changes.items, metas) |c, *m| {
        var hasher = std.hash.Wyhash.init(0);
        const ai_hash = if (c.a_idx) |ai| a_id[ai] else 0;
        const bi_hash = if (c.b_idx) |bi| b_id[bi] else 0;
        hasher.update(std.mem.asBytes(&ai_hash));
        hasher.update(std.mem.asBytes(&bi_hash));
        hasher.update(a.path);
        hasher.update(b.path);
        m.change_id = hasher.final();
    }
}
```

- [ ] **Step 3: Run; expect pass**

Run: `zig build test`
Expected: PASS.

#### Task 1.6e: `annotateLineChurn`

- [ ] **Step 1: Refactor `line_diff` to expose counts**

In `src/line_diff.zig`, add a new public function (do not touch `writeUnified`):

```zig
pub const Counts = struct { added: u32, removed: u32 };

/// Same LCS as writeUnified, but only returns counts. Allocates the DP table
/// and frees it before returning. Returns `.{ .added = 0, .removed = 0 }` if
/// `a == b`. Capped at the same `max_total_lines` as writeUnified — if exceeded
/// returns approximate counts based on byte length difference.
pub fn unifiedCounts(gpa: std.mem.Allocator, a: []const u8, b: []const u8) !Counts {
    if (std.mem.eql(u8, a, b)) return .{ .added = 0, .removed = 0 };

    var a_lines: std.ArrayList([]const u8) = .empty;
    defer a_lines.deinit(gpa);
    var b_lines: std.ArrayList([]const u8) = .empty;
    defer b_lines.deinit(gpa);

    try splitLines(gpa, a, &a_lines);
    try splitLines(gpa, b, &b_lines);

    const m = a_lines.items.len;
    const n = b_lines.items.len;
    if (m + n > default_limit.max_total_lines) {
        // Approximate: report each line as either fully added or removed.
        return .{ .added = @intCast(n), .removed = @intCast(m) };
    }

    const stride = n + 1;
    const dp = try gpa.alloc(u32, (m + 1) * stride);
    defer gpa.free(dp);
    @memset(dp, 0);
    var i: usize = 1;
    while (i <= m) : (i += 1) {
        var j: usize = 1;
        while (j <= n) : (j += 1) {
            if (std.mem.eql(u8, a_lines.items[i - 1], b_lines.items[j - 1])) {
                dp[i * stride + j] = dp[(i - 1) * stride + (j - 1)] + 1;
            } else {
                const up = dp[(i - 1) * stride + j];
                const left = dp[i * stride + (j - 1)];
                dp[i * stride + j] = if (up >= left) up else left;
            }
        }
    }
    const lcs = dp[m * stride + n];
    return .{ .added = @intCast(n - lcs), .removed = @intCast(m - lcs) };
}
```

- [ ] **Step 2: Test the counter**

In `src/line_diff.zig` test block:

```zig
test "unifiedCounts returns LCS-based add/remove" {
    const gpa = std.testing.allocator;
    const c = try unifiedCounts(gpa, "a\nb\nc\n", "a\nB\nc\n");
    try std.testing.expectEqual(@as(u32, 1), c.added);
    try std.testing.expectEqual(@as(u32, 1), c.removed);
}
```

Run: `zig build test`. Expected: PASS.

- [ ] **Step 3: Implement `annotateLineChurn`**

In `src/review.zig`:

```zig
pub fn annotateLineChurn(
    gpa: std.mem.Allocator,
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) !void {
    for (set.changes.items, metas) |c, *m| {
        switch (c.kind) {
            .modified => {
                const a_text = a.contentSlice(c.a_idx.?);
                const b_text = b.contentSlice(c.b_idx.?);
                const counts = try line_diff.unifiedCounts(gpa, a_text, b_text);
                m.lines_added = counts.added;
                m.lines_removed = counts.removed;
            },
            .added => {
                const text = b.contentSlice(c.b_idx.?);
                m.lines_added = countLines(text);
            },
            .deleted => {
                const text = a.contentSlice(c.a_idx.?);
                m.lines_removed = countLines(text);
            },
            .moved => {},
        }
    }
}

fn countLines(s: []const u8) u32 {
    var n: u32 = if (s.len == 0) 0 else 1;
    for (s) |c| if (c == '\n') { n += 1; };
    if (s.len > 0 and s[s.len - 1] == '\n') n -= 1;
    return n;
}
```

- [ ] **Step 4: Run; expect pass**

Run: `zig build test`
Expected: PASS.

#### Task 1.6f: `writeRecord` + JSON escape helper

- [ ] **Step 1: Implement**

```zig
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0C => try w.writeAll("\\f"),
        0...0x07, 0x0B, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn kindStr(k: differ.ChangeKind) []const u8 {
    return switch (k) {
        .added => "added",
        .deleted => "deleted",
        .modified => "modified",
        .moved => "moved",
    };
}

fn kindTagStr(t: KindTag) []const u8 {
    return switch (t) {
        .signature_change => "signature_change",
        .body_change => "body_change",
        .structural => "structural",
    };
}

fn writeRecord(
    w: *std.Io.Writer,
    c: *const differ.Change,
    m: *const ChangeMeta,
    a: *ast.Tree,
    b: *ast.Tree,
) !void {
    try w.print("{{\"kind\":\"{s}\",\"change_id\":\"{x:0>16}\",", .{ kindStr(c.kind), m.change_id });
    try w.writeAll("\"scope\":");
    try writeJsonString(w, m.scope);
    try w.print(",\"kind_tag\":\"{s}\",\"is_exported\":{},\"lines_added\":{d},\"lines_removed\":{d}", .{
        kindTagStr(m.kind_tag), m.is_exported, m.lines_added, m.lines_removed,
    });
    if (c.a_idx) |ai| {
        const lc = a.lineCol(ai);
        try w.writeAll(",\"a\":{\"path\":");
        try writeJsonString(w, a.path);
        try w.print(",\"line\":{d},\"col\":{d},\"text\":", .{ lc.line, lc.col });
        try writeJsonString(w, a.contentSlice(ai));
        try w.writeByte('}');
    }
    if (c.b_idx) |bi| {
        const lc = b.lineCol(bi);
        try w.writeAll(",\"b\":{\"path\":");
        try writeJsonString(w, b.path);
        try w.print(",\"line\":{d},\"col\":{d},\"text\":", .{ lc.line, lc.col });
        try writeJsonString(w, b.contentSlice(bi));
        try w.writeByte('}');
    }
    try w.writeAll("}\n");
}
```

- [ ] **Step 2: Run; expect green**

Run: `zig build test`
Expected: PASS.

---

### Task 1.7: Snapshot fixture — `body_only`

**Files:**
- Create: `testdata/review/body_only/a.go`
- Create: `testdata/review/body_only/b.go`
- Create: `testdata/review/body_only/expected.ndjson`

- [ ] **Step 1: Write the inputs**

`a.go`:

```go
package main

func Foo() int {
    return 1
}
```

`b.go`:

```go
package main

func Foo() int {
    return 2
}
```

- [ ] **Step 2: Generate `expected.ndjson` by running orchestrator manually**

Run from worktree root:

```bash
zig build && ./zig-out/bin/syndiff --review testdata/review/body_only/a.go testdata/review/body_only/b.go > testdata/review/body_only/expected.ndjson
```

(Uses CLI integration from Task 1.8.)

- [ ] **Step 3: Inspect manually**

Run: `cat testdata/review/body_only/expected.ndjson`
Expected output (whitespace and exact change_id will differ; verify the **shape**):

```
{"kind":"schema","version":"review-v1","syndiff":"0.1.0"}
{"kind":"modified","change_id":"...","scope":"Foo",...,"kind_tag":"body_change","is_exported":true,"lines_added":1,"lines_removed":1,...}
{"kind":"summary","files_changed":1,"counts":{"added":0,"deleted":0,"modified":1,"moved":0},"exported_changes":1}
```

- [ ] **Step 4: Enable snapshot test**

Edit `tests/review_snapshots.zig`, replace the placeholder test:

```zig
test "review snapshot: body_only" {
    try runCase(std.testing.allocator, "testdata/review/body_only");
}
```

Run: `zig build test`
Expected: PASS.

---

### Task 1.8: CLI plumbing — `--review` flag

**Files:**
- Modify: `src/main.zig:65` (`OutputFormat`), `src/main.zig:195-303` (`parseArgs`), `src/main.zig:524-562` (`diffOnePair`)

- [ ] **Step 1: Add test for parseArgs**

Append to `src/main.zig` test block:

```zig
test "parseArgs: --review sets format to review_json" {
    const r = parseArgs(&.{ "syndiff", "--review" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqual(OutputFormat.review_json, r.git.common.output);
}

test "parseArgs: --format=review-json" {
    const r = parseArgs(&.{ "syndiff", "--format=review-json" });
    try std.testing.expect(r == .git);
    try std.testing.expectEqual(OutputFormat.review_json, r.git.common.output);
}
```

- [ ] **Step 2: Run; expect compile error (no `review_json` variant)**

Run: `zig build test 2>&1 | head -10`
Expected: FAIL.

- [ ] **Step 3: Add `review_json` to `OutputFormat`**

Edit `src/main.zig:65-76`:

```zig
const OutputFormat = enum {
    text,
    json,
    yaml,
    review_json,

    fn parse(s: []const u8) ?OutputFormat {
        if (std.mem.eql(u8, s, "text")) return .text;
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "yaml")) return .yaml;
        if (std.mem.eql(u8, s, "review-json")) return .review_json;
        return null;
    }
};
```

And in `parseArgs` (`src/main.zig:218`-area), after the `--format` block:

```zig
if (std.mem.eql(u8, a, "--review")) {
    common.output = .review_json;
    continue;
}
```

- [ ] **Step 4: Wire `review_json` into `diffOnePair`**

Edit `src/main.zig:555-559`:

```zig
switch (output) {
    .text => try syndiff.differ.render(&set, &a_tree, &b_tree, stdout, opts),
    .json => try syndiff.differ.renderJson(&set, &a_tree, &b_tree, stdout),
    .yaml => try syndiff.differ.renderYaml(&set, &a_tree, &b_tree, stdout),
    .review_json => try syndiff.review.renderReviewJson(arena, &set, &a_tree, &b_tree, stdout),
}
```

- [ ] **Step 5: Update `usage` string**

Edit `src/main.zig:17-55`. Add to the Options block:

```
    \\  --review                         Emit enriched NDJSON for LLM review tools
    \\                                   (alias: --format review-json).
```

- [ ] **Step 6: Run; expect pass**

Run: `zig build test`
Expected: PASS, including the new parseArgs tests and the snapshot test from Task 1.7.

- [ ] **Step 7: Manual smoke test**

Run:

```bash
zig build && \
  echo 'package main' > /tmp/a.go && echo 'func Foo() {}' >> /tmp/a.go && \
  echo 'package main' > /tmp/b.go && echo 'func Foo() { return }' >> /tmp/b.go && \
  ./zig-out/bin/syndiff --review --files /tmp/a.go /tmp/b.go
```

Expected: 3 NDJSON lines (`schema`, one `modified`, `summary`).

---

### Task 1.9: JSON Schema for `review-v1`

**Files:**
- Create: `schemas/review-v1.json`
- Create: `tests/schema_validation.zig`

The JSON Schema documents the stream shape and lets downstream consumers validate. For Phase 1, validation is by-eye + a tiny embedded Zig validator that checks required fields exist; full JSON Schema validation (e.g. via a draft-07 validator) is out of scope.

- [ ] **Step 1: Write the schema**

Create `schemas/review-v1.json`:

```json
{
  "$schema": "https://json-schema.org/draft-07/schema",
  "title": "syndiff review-v1 NDJSON record",
  "oneOf": [
    {
      "type": "object",
      "required": ["kind", "version"],
      "properties": {
        "kind": { "const": "schema" },
        "version": { "const": "review-v1" },
        "syndiff": { "type": "string" }
      }
    },
    {
      "type": "object",
      "required": ["kind", "change_id", "scope", "kind_tag", "is_exported", "lines_added", "lines_removed"],
      "properties": {
        "kind": { "enum": ["added", "deleted", "modified", "moved"] },
        "change_id": { "type": "string", "pattern": "^[0-9a-f]{16}$" },
        "scope": { "type": "string" },
        "kind_tag": { "enum": ["signature_change", "body_change", "structural"] },
        "is_exported": { "type": "boolean" },
        "lines_added": { "type": "integer", "minimum": 0 },
        "lines_removed": { "type": "integer", "minimum": 0 },
        "a": { "$ref": "#/$defs/loc" },
        "b": { "$ref": "#/$defs/loc" }
      }
    },
    {
      "type": "object",
      "required": ["kind", "files_changed", "counts"],
      "properties": {
        "kind": { "const": "summary" },
        "files_changed": { "type": "integer", "minimum": 0 },
        "counts": {
          "type": "object",
          "required": ["added", "deleted", "modified", "moved"]
        },
        "exported_changes": { "type": "integer", "minimum": 0 }
      }
    }
  ],
  "$defs": {
    "loc": {
      "type": "object",
      "required": ["path", "line", "col", "text"],
      "properties": {
        "path": { "type": "string" },
        "line": { "type": "integer", "minimum": 1 },
        "col": { "type": "integer", "minimum": 1 },
        "text": { "type": "string" }
      }
    }
  }
}
```

- [ ] **Step 2: Add a sanity test**

Create `tests/schema_validation.zig`:

```zig
//! Lightweight check: the body_only fixture's NDJSON must include each
//! required Phase 1 key. Real JSON Schema validation is deferred.

const std = @import("std");

test "body_only fixture has all required Phase 1 keys" {
    const gpa = std.testing.allocator;
    const ndjson = try std.fs.cwd().readFileAlloc(gpa, "testdata/review/body_only/expected.ndjson", 1 << 16);
    defer gpa.free(ndjson);

    const required = [_][]const u8{
        "\"kind\":\"schema\"",
        "\"version\":\"review-v1\"",
        "\"change_id\"",
        "\"scope\"",
        "\"kind_tag\"",
        "\"is_exported\"",
        "\"lines_added\"",
        "\"lines_removed\"",
        "\"kind\":\"summary\"",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, ndjson, needle) == null) {
            std.debug.print("missing key: {s}\n", .{needle});
            return error.MissingRequiredKey;
        }
    }
}
```

- [ ] **Step 3: Wire into build.zig**

Add `schema_tests` mirroring the pattern from Task 0.2.

- [ ] **Step 4: Run**

Run: `zig build test`
Expected: PASS.

---

### Task 1.10: Phase 1 verification gate

- [ ] **Step 1: Full test run**

Run: `zig build test 2>&1 | tail -5`
Expected: all suites pass.

- [ ] **Step 2: Confirm goldens unchanged**

Run: `zig build run -- --files testdata/review/body_only/a.go testdata/review/body_only/b.go --format json --no-color | diff - testdata/golden/json_modified.golden || echo "expected: goldens are scoped to their original inputs, not body_only"`
This is a sanity check that `--format json` still emits the same byte stream for the **original** golden inputs:

```bash
echo '{"name":"alice","age":30}' > /tmp/g_a.json
echo '{"name":"alice","age":31,"new_field":true}' > /tmp/g_b.json
zig build run -- --files /tmp/g_a.json /tmp/g_b.json --format json --no-color | diff - testdata/golden/json_modified.golden
```

Expected: empty diff.

- [ ] **Step 3: Manual --review on this repo's history**

Run:

```bash
./zig-out/bin/syndiff --review HEAD~1 HEAD | head -10
```

Expected: schema header + modified records + summary, all valid JSON per line (`jq .` on each line round-trips).

---

## Phase 2 — Tier 2: Signatures + Sensitivity

### Task 2.1: `src/signature.zig` — extract Signature per language

**Files:**
- Create: `src/signature.zig`
- Modify: `src/root.zig` (re-export)

```zig
//! Per-language signature extraction. Operates on a single Node — does NOT
//! re-tokenize or re-parse files. Each per-language sub-extractor uses byte
//! ranges (`content_range`, `identity_range`) plus a small ad-hoc tokenizer
//! over the content slice to pull out params and return type.

const std = @import("std");
const ast = @import("ast.zig");

pub const Param = struct {
    name: []const u8,
    type_str: []const u8,
    has_default: bool,
};

pub const Visibility = enum { private, public, protected, package };

pub const Modifiers = packed struct(u8) {
    is_async: bool = false,
    is_static: bool = false,
    is_const: bool = false,
    is_unsafe: bool = false,
    _pad: u4 = 0,
};

pub const Signature = struct {
    name: []const u8,
    params: []Param,
    return_type: ?[]const u8,
    visibility: Visibility,
    modifiers: Modifiers,
    /// Wyhash over name + concatenated param types + return type. Used by
    /// rename pairing in Tier 3.
    hash: u64,
};

/// Returns `null` for nodes that aren't fn/method-shaped (e.g. structs,
/// imports, statements). Each per-language extractor below dispatches on
/// `Node.kind`.
pub fn extract(
    gpa: std.mem.Allocator,
    tree: *ast.Tree,
    idx: ast.NodeIndex,
) !?Signature {
    const kind = tree.nodes.items(.kind)[idx];
    return switch (kind) {
        .go_fn, .go_method => try extractGo(gpa, tree, idx),
        .rust_fn => try extractRust(gpa, tree, idx),
        .zig_fn => try extractZig(gpa, tree, idx),
        .dart_fn, .dart_method => try extractDart(gpa, tree, idx),
        .js_function, .js_method => try extractJs(gpa, tree, idx),
        else => null,
    };
}

// Per-language extractors below — each ~30-60 lines.
fn extractGo(gpa: std.mem.Allocator, tree: *ast.Tree, idx: ast.NodeIndex) !?Signature {
    // Slice = "func [(recv T)] Name(p1 T1, p2 T2) RetType { ... }"
    // Find first '(' after `func`/receiver → opening of param list.
    // Walk balanced parens, split by ',' at depth 0.
    // After matching ')', whatever is between ')' and '{' (or EOL) is return.
    // Visibility = uppercase first letter of name → public, else private.
    _ = gpa; _ = tree; _ = idx;
    return error.Unimplemented; // Filled in Step 4.
}

fn extractRust(gpa: std.mem.Allocator, tree: *ast.Tree, idx: ast.NodeIndex) !?Signature {
    _ = gpa; _ = tree; _ = idx;
    return error.Unimplemented;
}

fn extractZig(gpa: std.mem.Allocator, tree: *ast.Tree, idx: ast.NodeIndex) !?Signature {
    _ = gpa; _ = tree; _ = idx;
    return error.Unimplemented;
}

fn extractDart(gpa: std.mem.Allocator, tree: *ast.Tree, idx: ast.NodeIndex) !?Signature {
    _ = gpa; _ = tree; _ = idx;
    return error.Unimplemented;
}

fn extractJs(gpa: std.mem.Allocator, tree: *ast.Tree, idx: ast.NodeIndex) !?Signature {
    _ = gpa; _ = tree; _ = idx;
    return error.Unimplemented;
}
```

- [ ] **Step 1: Add stub + smoke test**

Create the file above and add:

```zig
test "extract returns null for non-fn kinds" {
    const gpa = std.testing.allocator;
    var tree = ast.Tree.init(gpa, "{}", "x.json");
    defer tree.deinit();
    var n = ast.Node{ .hash = 0, .identity_hash = 0, .identity_range_hash = 0, .kind = .json_object, .depth = 0, .parent_idx = ast.ROOT_PARENT, .content_range = .{ .start = 0, .end = 2 }, .identity_range = ast.Range.empty, .is_exported = false };
    _ = try tree.addNode(n);
    const sig = try extract(gpa, &tree, 0);
    try std.testing.expect(sig == null);
}
```

Run: `zig build test`. Expected: PASS.

- [ ] **Step 2: Implement `extractGo` with TDD**

Write the test first:

```zig
const go_parser = @import("go_parser.zig");

test "extractGo: simple fn with params and return type" {
    const gpa = std.testing.allocator;
    var tree = try go_parser.parse(gpa, "package main\nfunc Add(a int, b int) int { return a + b }\n", "x.go");
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var fn_idx: ast.NodeIndex = 0;
    for (kinds, 0..) |k, i| if (k == .go_fn) { fn_idx = @intCast(i); break; };

    const sig = (try extract(gpa, &tree, fn_idx)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("Add", sig.name);
    try std.testing.expectEqual(@as(usize, 2), sig.params.len);
    try std.testing.expectEqualStrings("a", sig.params[0].name);
    try std.testing.expectEqualStrings("int", sig.params[0].type_str);
    try std.testing.expectEqualStrings("int", sig.params[1].type_str);
    try std.testing.expect(sig.return_type != null);
    try std.testing.expectEqualStrings("int", sig.return_type.?);
    try std.testing.expectEqual(Visibility.public, sig.visibility);
}
```

Run; FAIL with `error.Unimplemented`. Then implement `extractGo`:

```zig
fn extractGo(gpa: std.mem.Allocator, tree: *ast.Tree, idx: ast.NodeIndex) !?Signature {
    const ranges = tree.nodes.items(.content_range);
    const ident_ranges = tree.nodes.items(.identity_range);
    const r = ranges[idx];
    const slice = tree.source[r.start..r.end];
    const name = tree.source[ident_ranges[idx].start..ident_ranges[idx].end];

    // Find `(` after the name.
    const name_end_in_slice = (ident_ranges[idx].end) - r.start;
    const paren_open = std.mem.indexOfScalarPos(u8, slice, name_end_in_slice, '(') orelse return null;

    // Find balanced `)`.
    var depth: u32 = 0;
    var i: usize = paren_open;
    var paren_close: usize = paren_open;
    while (i < slice.len) : (i += 1) {
        switch (slice[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) { paren_close = i; break; }
            },
            else => {},
        }
    }

    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(gpa);

    // Split between paren_open+1 and paren_close by comma at depth 0.
    var seg_start: usize = paren_open + 1;
    var d: u32 = 0;
    var k: usize = paren_open + 1;
    while (k <= paren_close) : (k += 1) {
        const c = if (k < slice.len) slice[k] else ',';
        if (c == '(' or c == '[' or c == '{') d += 1;
        if (c == ')' or c == ']' or c == '}') {
            if (d == 0 and c == ')' and k == paren_close) {
                try pushGoParam(gpa, &params, slice[seg_start..k]);
                break;
            }
            if (d > 0) d -= 1;
        }
        if (c == ',' and d == 0) {
            try pushGoParam(gpa, &params, slice[seg_start..k]);
            seg_start = k + 1;
        }
    }

    // Return type = trimmed slice between paren_close+1 and `{` (or EOL).
    var ret: ?[]const u8 = null;
    var post: usize = paren_close + 1;
    while (post < slice.len and (slice[post] == ' ' or slice[post] == '\t')) post += 1;
    if (post < slice.len and slice[post] != '{' and slice[post] != '\n') {
        const brace = std.mem.indexOfScalarPos(u8, slice, post, '{') orelse slice.len;
        const r_str = std.mem.trim(u8, slice[post..brace], " \t");
        if (r_str.len > 0) ret = r_str;
    }

    const visibility: Visibility = if (name.len > 0 and std.ascii.isUpper(name[0])) .public else .private;

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    for (params.items) |p| hasher.update(p.type_str);
    if (ret) |s| hasher.update(s);

    return .{
        .name = name,
        .params = try params.toOwnedSlice(gpa),
        .return_type = ret,
        .visibility = visibility,
        .modifiers = .{},
        .hash = hasher.final(),
    };
}

fn pushGoParam(gpa: std.mem.Allocator, list: *std.ArrayList(Param), seg: []const u8) !void {
    const trimmed = std.mem.trim(u8, seg, " \t\n");
    if (trimmed.len == 0) return;
    // Go params: "name type" or just "type" (anonymous). Split on last whitespace.
    var split: usize = trimmed.len;
    var i: usize = trimmed.len;
    while (i > 0) {
        i -= 1;
        if (trimmed[i] == ' ' or trimmed[i] == '\t') { split = i; break; }
    }
    if (split == trimmed.len) {
        try list.append(gpa, .{ .name = "", .type_str = trimmed, .has_default = false });
    } else {
        try list.append(gpa, .{
            .name = std.mem.trim(u8, trimmed[0..split], " \t"),
            .type_str = std.mem.trim(u8, trimmed[split + 1 ..], " \t"),
            .has_default = false,
        });
    }
}
```

Run: `zig build test`. Expected: PASS.

- [ ] **Step 3: Repeat for `extractRust`, `extractZig`, `extractDart`, `extractJs`**

Each extractor follows the same pattern (find `(`, scan to balanced `)`, split by depth-0 commas). Differences:
- **Rust**: type appears AFTER `:` in each param (`name: Type`); return after `->`. Skip leading `pub fn`. Keywords (`unsafe`, `async`, `const`) → modifiers.
- **Zig**: same as Rust syntax-wise but `pub fn` and `!Error` returns; type is space-separated (`name: Type`).
- **Dart**: types come BEFORE names (`Type name`); returns are also before the name (`Type Name(...)`). Skip optional `static`, `const`, `final` modifiers.
- **JS**: no types unless TS. Just param names; `return_type = null`. Async / static modifiers from leading keywords.

For each, write a TDD test first (one positive case per language) before implementing.

Suggested test inputs:

| Lang | Input | Expected |
|------|-------|----------|
| Rust | `fn add(a: i32, b: i32) -> i32 { 0 }` | name=add, 2 params (i32,i32), ret=i32 |
| Zig | `pub fn add(a: u32, b: u32) u32 { return 0; }` | same shape |
| Dart | `int add(int a, int b) => a + b;` | name=add, ret="int" |
| JS | `function add(a, b) { return a + b; }` | name=add, ret=null |

- [ ] **Step 4: Re-export from root**

Add `pub const signature = @import("signature.zig");` to `src/root.zig` and `_ = signature;` in the test block.

Run: `zig build test`. Expected: PASS.

---

### Task 2.2: `annotateSignatureDelta` in review.zig

**Files:**
- Modify: `src/review.zig`

For each `modified` change with `kind_tag == .signature_change` (or any `modified` of fn/method kind), extract Signature for both sides, diff `params` (added / removed / changed by name), compare return types, compare visibility.

- [ ] **Step 1: Test**

```zig
test "annotateSignatureDelta: param added" {
    const gpa = std.testing.allocator;
    var a = try go_parser.parse(gpa, "package main\nfunc Foo(x int) {}\n", "a.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo(x int, y string) {}\n", "b.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);

    const metas = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer gpa.free(metas);
    for (metas) |*m| m.* = .{};
    try annotateSignatureDelta(gpa, &set, &a, &b, metas);

    var found = false;
    for (metas) |m| {
        if (m.signature_diff) |sd| {
            try std.testing.expectEqual(@as(usize, 1), sd.params_added.len);
            try std.testing.expectEqualStrings("y", sd.params_added[0].name);
            found = true;
        }
    }
    try std.testing.expect(found);
}
```

- [ ] **Step 2: Add SignatureDiff to ChangeMeta**

```zig
pub const SignatureDiff = struct {
    params_added: []const signature.Param = &.{},
    params_removed: []const signature.Param = &.{},
    params_changed: []const ParamChange = &.{},
    return_changed: bool = false,
    visibility_changed: bool = false,
};

pub const ParamChange = struct {
    name: []const u8,
    from: []const u8,
    to: []const u8,
};

// In ChangeMeta struct:
pub const ChangeMeta = struct {
    // ... existing fields ...
    signature_diff: ?SignatureDiff = null,
};
```

- [ ] **Step 3: Implement**

```zig
const signature = @import("signature.zig");

pub fn annotateSignatureDelta(
    gpa: std.mem.Allocator,
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) !void {
    for (set.changes.items, metas) |c, *m| {
        if (c.kind != .modified) continue;
        const sig_a = (try signature.extract(gpa, a, c.a_idx.?)) orelse continue;
        const sig_b = (try signature.extract(gpa, b, c.b_idx.?)) orelse continue;
        defer gpa.free(sig_a.params);
        defer gpa.free(sig_b.params);

        var added: std.ArrayList(signature.Param) = .empty;
        var removed: std.ArrayList(signature.Param) = .empty;
        var changed: std.ArrayList(ParamChange) = .empty;

        // Match by name.
        for (sig_b.params) |pb| {
            var matched = false;
            for (sig_a.params) |pa| {
                if (std.mem.eql(u8, pa.name, pb.name)) {
                    if (!std.mem.eql(u8, pa.type_str, pb.type_str)) {
                        try changed.append(gpa, .{ .name = pb.name, .from = pa.type_str, .to = pb.type_str });
                    }
                    matched = true;
                    break;
                }
            }
            if (!matched) try added.append(gpa, pb);
        }
        for (sig_a.params) |pa| {
            var matched = false;
            for (sig_b.params) |pb| {
                if (std.mem.eql(u8, pa.name, pb.name)) { matched = true; break; }
            }
            if (!matched) try removed.append(gpa, pa);
        }

        const ret_changed = !std.meta.eql(sig_a.return_type, sig_b.return_type);
        const vis_changed = sig_a.visibility != sig_b.visibility;

        m.signature_diff = .{
            .params_added = try added.toOwnedSlice(gpa),
            .params_removed = try removed.toOwnedSlice(gpa),
            .params_changed = try changed.toOwnedSlice(gpa),
            .return_changed = ret_changed,
            .visibility_changed = vis_changed,
        };
    }
}
```

- [ ] **Step 4: Render signature_diff in writeRecord**

Append to `writeRecord` (after `lines_removed`):

```zig
if (m.signature_diff) |sd| {
    try w.writeAll(",\"signature_diff\":{\"params_added\":[");
    for (sd.params_added, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try writeJsonString(w, p.name);
        try w.writeAll(",\"type\":");
        try writeJsonString(w, p.type_str);
        try w.writeByte('}');
    }
    try w.writeAll("],\"params_removed\":[");
    // ... mirror for params_removed and params_changed ...
    try w.writeAll("]");
    try w.print(",\"return_changed\":{},\"visibility_changed\":{}", .{ sd.return_changed, sd.visibility_changed });
    try w.writeByte('}');
}
```

- [ ] **Step 5: Wire into renderReviewJson**

Add `try annotateSignatureDelta(gpa, set, a, b, metas);` after `annotateLineChurn`.

- [ ] **Step 6: Run**

Run: `zig build test`. Expected: PASS.

---

### Task 2.3: `src/sensitivity.zig` — regex-style tagger

**Files:**
- Create: `src/sensitivity.zig`
- Modify: `src/root.zig`

Zig has no regex in std. Use case-insensitive substring lookups + word-boundary checks via tiny helpers. Tags are a fixed set; keep the implementation deliberately dumb.

- [ ] **Step 1: Test**

Create `src/sensitivity.zig`:

```zig
//! Heuristic sensitivity tagger. Single byte-scan per change. False positives
//! are explicitly tolerated — the review agent decides relevance.

const std = @import("std");

pub const Tag = enum {
    crypto,
    auth,
    sql,
    shell,
    network,
    fs_io,
    secrets,

    pub fn name(self: Tag) []const u8 {
        return switch (self) {
            .crypto => "crypto",
            .auth => "auth",
            .sql => "sql",
            .shell => "shell",
            .network => "network",
            .fs_io => "fs_io",
            .secrets => "secrets",
        };
    }
};

pub const TagSet = std.EnumSet(Tag);

const Pattern = struct {
    needle: []const u8,
    case_insensitive: bool = false,
    /// If set, the byte before/after the needle must be a non-identifier byte.
    word_boundary: bool = false,
    tag: Tag,
};

const PATTERNS = [_]Pattern{
    .{ .needle = "sha", .word_boundary = true, .tag = .crypto },
    .{ .needle = "md5", .word_boundary = true, .tag = .crypto },
    .{ .needle = "hmac", .word_boundary = true, .tag = .crypto },
    .{ .needle = "aes", .word_boundary = true, .tag = .crypto },
    .{ .needle = "rsa", .word_boundary = true, .tag = .crypto },
    .{ .needle = "bcrypt", .tag = .crypto },
    .{ .needle = "argon2", .tag = .crypto },
    .{ .needle = "encrypt", .tag = .crypto },
    .{ .needle = "decrypt", .tag = .crypto },
    .{ .needle = "password", .case_insensitive = true, .tag = .auth },
    .{ .needle = "token", .case_insensitive = true, .word_boundary = true, .tag = .auth },
    .{ .needle = "jwt", .case_insensitive = true, .tag = .auth },
    .{ .needle = "session", .case_insensitive = true, .word_boundary = true, .tag = .auth },
    .{ .needle = "oauth", .case_insensitive = true, .tag = .auth },
    .{ .needle = "login", .case_insensitive = true, .word_boundary = true, .tag = .auth },
    .{ .needle = "permission", .case_insensitive = true, .tag = .auth },
    .{ .needle = "SELECT ", .tag = .sql },
    .{ .needle = "INSERT ", .tag = .sql },
    .{ .needle = "UPDATE ", .tag = .sql },
    .{ .needle = "DELETE ", .tag = .sql },
    .{ .needle = "DROP ", .tag = .sql },
    .{ .needle = "exec(", .tag = .shell },
    .{ .needle = "os/exec", .tag = .shell },
    .{ .needle = "subprocess", .tag = .shell },
    .{ .needle = "Runtime.getRuntime", .tag = .shell },
    .{ .needle = "http.", .tag = .network },
    .{ .needle = "fetch(", .tag = .network },
    .{ .needle = "axios", .tag = .network },
    .{ .needle = "ioutil.", .tag = .fs_io },
    .{ .needle = "WriteFile", .tag = .fs_io },
    .{ .needle = "removeAll", .tag = .fs_io },
    .{ .needle = "os.Getenv", .tag = .secrets },
    .{ .needle = "process.env.", .tag = .secrets },
    .{ .needle = "apiKey", .case_insensitive = true, .tag = .secrets },
    .{ .needle = "AWS_", .tag = .secrets },
};

pub fn tag(haystack: []const u8) TagSet {
    var set = TagSet.initEmpty();
    for (PATTERNS) |p| {
        if (matches(haystack, p)) set.insert(p.tag);
    }
    return set;
}

fn matches(haystack: []const u8, p: Pattern) bool {
    if (p.case_insensitive) {
        return indexOfCaseInsensitive(haystack, p.needle, p.word_boundary) != null;
    } else {
        return indexOfExact(haystack, p.needle, p.word_boundary) != null;
    }
}

fn indexOfExact(haystack: []const u8, needle: []const u8, word_boundary: bool) ?usize {
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            if (!word_boundary) return i;
            const left_ok = i == 0 or !isIdent(haystack[i - 1]);
            const right_ok = i + needle.len == haystack.len or !isIdent(haystack[i + needle.len]);
            if (left_ok and right_ok) return i;
        }
    }
    return null;
}

fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8, word_boundary: bool) ?usize {
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            if (!word_boundary) return i;
            const left_ok = i == 0 or !isIdent(haystack[i - 1]);
            const right_ok = i + needle.len == haystack.len or !isIdent(haystack[i + needle.len]);
            if (left_ok and right_ok) return i;
        }
    }
    return null;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "auth + crypto detection" {
    const t = tag("func login(password string) { hmac.New(sha256.New, key) }");
    try std.testing.expect(t.contains(.auth));
    try std.testing.expect(t.contains(.crypto));
    try std.testing.expect(!t.contains(.sql));
}

test "no false positive: 'shadowed' does not trigger crypto via 'sha'" {
    const t = tag("var shadowed = 1");
    try std.testing.expect(!t.contains(.crypto));
}

test "sql case-sensitive: 'SELECT FROM' tags sql" {
    const t = tag("db.Query(\"SELECT * FROM users\")");
    try std.testing.expect(t.contains(.sql));
}

test "sql: lowercase 'select' does NOT tag (intentional)" {
    const t = tag("user.select(filter)");
    try std.testing.expect(!t.contains(.sql));
}
```

- [ ] **Step 2: Run**

Run: `zig build test`. Expected: PASS.

- [ ] **Step 3: Wire into review.zig**

```zig
const sensitivity = @import("sensitivity.zig");

// Add to ChangeMeta:
sensitivity_tags: sensitivity.TagSet = sensitivity.TagSet.initEmpty(),

pub fn annotateSensitivity(
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) void {
    for (set.changes.items, metas) |c, *m| {
        const text = if (c.b_idx) |bi| b.contentSlice(bi)
                     else if (c.a_idx) |ai| a.contentSlice(ai)
                     else "";
        m.sensitivity_tags = sensitivity.tag(text);
    }
}
```

In `writeRecord`, after `is_exported`:

```zig
var iter = m.sensitivity_tags.iterator();
var first = true;
try w.writeAll(",\"sensitivity\":[");
while (iter.next()) |t| {
    if (!first) try w.writeByte(',');
    first = false;
    try writeJsonString(w, t.name());
}
try w.writeByte(']');
```

In `renderReviewJson`, after `annotateSignatureDelta`: `annotateSensitivity(set, a, b, metas);`.

Add to summary: `sensitivity_totals` (per-tag counts) — implement same way as `counts`.

- [ ] **Step 4: Snapshot test**

Create `testdata/review/security_touch/`:

```go
// a.go
package main

func Login(user string, pw string) bool {
    return user == "admin" && pw == "hunter2"
}
```

```go
// b.go
package main

import "crypto/sha256"

func Login(user string, pw string) bool {
    h := sha256.Sum256([]byte(pw))
    return user == "admin" && string(h[:]) == "..."
}
```

Generate `expected.ndjson` via `./zig-out/bin/syndiff --review`. Verify it includes `"sensitivity":["auth","crypto"]`.

Add to `tests/review_snapshots.zig`:

```zig
test "review snapshot: security_touch" {
    try runCase(std.testing.allocator, "testdata/review/security_touch");
}
```

Run: `zig build test`. Expected: PASS.

---

### Task 2.4: Phase 2 verification gate

- [ ] **Step 1: Full test run**

Run: `zig build test`
Expected: all suites pass.

- [ ] **Step 2: Schema bump check**

Open `schemas/review-v1.json` and add `sensitivity` (array of strings) and `signature_diff` (object) to the optional properties of the change record. Re-run schema validation test from Task 1.9.

- [ ] **Step 3: Goldens still byte-stable**

Run: `zig build test 2>&1 | grep golden`
Expected: PASS.

---

## Phase 3 — Tier 3: Rename, Symbols, Complexity, Test Pairing, Group-By

### Task 3.1: `src/rename.zig` — pair (added, deleted) into `renamed`

**Files:**
- Create: `src/rename.zig`
- Modify: `src/root.zig`, `src/review.zig`

Pairing rules:
1. Both must share parent scope (same `parent_idx`'s identity_hash, or both at root).
2. Either: `Signature.hash` matches (Tier 2), OR full subtree `Node.hash` matches (body intact, name changed).
3. Otherwise leave unpaired.

When a pair is found, the orchestrator:
- Replaces one of the two `Change` rows with a synthetic one of new kind `.renamed` (extension to `differ.ChangeKind`).
- Drops the other row.
- Decrements `summary.counts.added` and `summary.counts.deleted` by 1 each.

**Decision: extend ChangeKind in differ.zig.** Existing `--format json|yaml` only emit "added/deleted/modified/moved", so adding a fifth variant requires updating those renderers' switch statements with a no-op or pass-through. To preserve goldens, `renamed` is set ONLY by review-mode post-processing — `differ.diff` itself never produces `.renamed`. The other renderers will still see only the original four kinds.

- [ ] **Step 1: Add `.renamed` to ChangeKind, update all switches**

Edit `src/differ.zig:37-42`:

```zig
pub const ChangeKind = enum {
    added,
    deleted,
    modified,
    moved,
    renamed,
};
```

Update `KindFilter` (lines 44-77) and `kindStr` (line 305). For `KindFilter`, default `.renamed = true`. For `allows`, add the case.

In `renderJson` and `renderYaml`, the existing switches don't enumerate kinds — they call `kindStr` — so they already emit "renamed" if a row of that kind ever reaches them. Goldens are unaffected because `differ.diff` won't produce `.renamed` rows.

In `render` (text), add a `.renamed` branch matching `.modified` shape but with label "RENAMED".

- [ ] **Step 2: Test for rename detection**

Create `src/rename.zig`:

```zig
//! Pairs (deleted, added) Change pairs into a single `.renamed` row.
//!
//! Rules: same parent scope + (Signature.hash match OR subtree hash match).
//! Mutates the DiffSet in place.

const std = @import("std");
const ast = @import("ast.zig");
const differ = @import("differ.zig");
const signature = @import("signature.zig");

pub fn pairRenames(
    gpa: std.mem.Allocator,
    set: *differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
) !void {
    const parents_a = a.nodes.items(.parent_idx);
    const parents_b = b.nodes.items(.parent_idx);
    const a_id = a.nodes.items(.identity_hash);
    const b_id = b.nodes.items(.identity_hash);
    const a_hash = a.nodes.items(.hash);
    const b_hash = b.nodes.items(.hash);

    var to_drop: std.AutoHashMap(usize, void) = .init(gpa);
    defer to_drop.deinit();

    for (set.changes.items, 0..) |ca, i| {
        if (ca.kind != .deleted) continue;
        if (to_drop.contains(i)) continue;
        const ai = ca.a_idx.?;
        const a_parent_id = if (parents_a[ai] == ast.ROOT_PARENT) 0 else a_id[parents_a[ai]];

        for (set.changes.items, 0..) |cb, j| {
            if (i == j) continue;
            if (cb.kind != .added) continue;
            if (to_drop.contains(j)) continue;
            const bi = cb.b_idx.?;
            const b_parent_id = if (parents_b[bi] == ast.ROOT_PARENT) 0 else b_id[parents_b[bi]];
            if (a_parent_id != b_parent_id) continue;

            const subtree_match = a_hash[ai] == b_hash[bi];
            const sig_match = blk: {
                const sa = (try signature.extract(gpa, a, ai)) orelse break :blk false;
                defer gpa.free(sa.params);
                const sb = (try signature.extract(gpa, b, bi)) orelse break :blk false;
                defer gpa.free(sb.params);
                break :blk sa.hash == sb.hash;
            };
            if (!subtree_match and !sig_match) continue;

            // Convert `i` to renamed; drop `j`.
            set.changes.items[i] = .{ .kind = .renamed, .a_idx = ai, .b_idx = bi };
            try to_drop.put(j, {});
            break;
        }
    }

    // Compact.
    var w: usize = 0;
    for (set.changes.items, 0..) |c, idx| {
        if (to_drop.contains(idx)) continue;
        set.changes.items[w] = c;
        w += 1;
    }
    set.changes.shrinkRetainingCapacity(w);
}

const go_parser = @import("go_parser.zig");

test "pairRenames: same body, new name → renamed" {
    const gpa = std.testing.allocator;
    var a = try go_parser.parse(gpa, "package main\nfunc OldName() { x := 1; _ = x }\n", "a.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc NewName() { x := 1; _ = x }\n", "b.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);

    var added_before: u32 = 0;
    var deleted_before: u32 = 0;
    for (set.changes.items) |c| {
        if (c.kind == .added) added_before += 1;
        if (c.kind == .deleted) deleted_before += 1;
    }
    try std.testing.expect(added_before >= 1 and deleted_before >= 1);

    try pairRenames(gpa, &set, &a, &b);

    var renamed: u32 = 0;
    for (set.changes.items) |c| if (c.kind == .renamed) { renamed += 1; };
    try std.testing.expect(renamed >= 1);
}
```

- [ ] **Step 3: Run**

Run: `zig build test`. Expected: PASS.

- [ ] **Step 4: Wire into review pipeline**

In `src/review.zig`, in `renderReviewJson` BEFORE allocating `metas`:

```zig
try @import("rename.zig").pairRenames(gpa, set, a, b);
```

Update `kindStr` in writeRecord switch (or just rely on `differ.kindStr` if you reuse it). Update summary `counts` to track `renamed`.

- [ ] **Step 5: Snapshot test**

`testdata/review/rename_only/{a.rs, b.rs, expected.ndjson}`:

```rust
// a.rs
pub fn old_name(x: i32) -> i32 { x + 1 }
```

```rust
// b.rs
pub fn new_name(x: i32) -> i32 { x + 1 }
```

(Run TDD-style: generate, eyeball, snapshot, add test.)

---

### Task 3.2: `complexity_delta` — `*_stmt` child counts

**Files:**
- Modify: `src/review.zig`

Cheap proxy: `childrenOf(fn_idx)` in tree A vs B; count nodes with kind matching `*_stmt`.

- [ ] **Step 1: Test**

```zig
test "complexity_delta counts stmt children" {
    const gpa = std.testing.allocator;
    var a = try go_parser.parse(gpa, "package main\nfunc Foo() { a := 1; _ = a }\n", "a.go");
    defer a.deinit();
    var b = try go_parser.parse(gpa, "package main\nfunc Foo() { a := 1; b := 2; _ = a + b }\n", "b.go");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);
    try differ.suppressCascade(&set, &a, &b, gpa);

    const metas = try gpa.alloc(ChangeMeta, set.changes.items.len);
    defer gpa.free(metas);
    for (metas) |*m| m.* = .{};
    try annotateComplexity(gpa, &set, &a, &b, metas);

    var found = false;
    for (metas) |m| {
        if (m.complexity_delta) |cd| {
            try std.testing.expect(cd.delta > 0);
            try std.testing.expect(cd.stmt_b > cd.stmt_a);
            found = true;
        }
    }
    try std.testing.expect(found);
}
```

- [ ] **Step 2: Add field + implement**

```zig
pub const ComplexityDelta = struct { stmt_a: u32, stmt_b: u32, delta: i32 };

// In ChangeMeta:
complexity_delta: ?ComplexityDelta = null,

pub fn annotateComplexity(
    gpa: std.mem.Allocator,
    set: *const differ.DiffSet,
    a: *ast.Tree,
    b: *ast.Tree,
    metas: []ChangeMeta,
) !void {
    for (set.changes.items, metas) |c, *m| {
        if (c.kind != .modified and c.kind != .renamed) continue;
        const ai = c.a_idx.?;
        const bi = c.b_idx.?;
        const sa = try countStmtChildren(gpa, a, ai);
        const sb = try countStmtChildren(gpa, b, bi);
        m.complexity_delta = .{ .stmt_a = sa, .stmt_b = sb, .delta = @as(i32, @intCast(sb)) - @as(i32, @intCast(sa)) };
    }
}

fn countStmtChildren(gpa: std.mem.Allocator, tree: *ast.Tree, parent: ast.NodeIndex) !u32 {
    var buf: std.ArrayList(ast.NodeIndex) = .empty;
    defer buf.deinit(gpa);
    try tree.childrenOf(gpa, parent, &buf);
    var n: u32 = 0;
    const kinds = tree.nodes.items(.kind);
    for (buf.items) |i| {
        const k = kinds[i];
        if (k == .rust_stmt or k == .go_stmt or k == .zig_stmt or k == .dart_stmt or k == .js_stmt or k == .ts_stmt) n += 1;
    }
    return n;
}
```

Render in `writeRecord`:

```zig
if (m.complexity_delta) |cd| {
    try w.print(",\"complexity_delta\":{{\"stmt_a\":{d},\"stmt_b\":{d},\"delta\":{d}}}", .{ cd.stmt_a, cd.stmt_b, cd.delta });
}
```

- [ ] **Step 3: Run**

Run: `zig build test`. Expected: PASS.

---

### Task 3.3: `src/test_pair.zig` — test_not_updated record

**Files:**
- Create: `src/test_pair.zig`
- Modify: `src/review.zig`, `src/main.zig` (multi-file driver)

Heuristic: per-language convention.

| Lang | Source | Test |
|------|--------|------|
| Go   | `foo.go` | `foo_test.go` |
| JS/TS | `foo.ts` | `foo.test.ts` / `foo.spec.ts` / `__tests__/foo.ts` |
| Dart | `lib/foo.dart` | `test/foo_test.dart` |
| Rust | (skip — inline `#[cfg(test)]`) | — |

Driver: after collecting the union of changed paths from `git.listChangedFiles`, for each non-test source path with a tests-expected match, emit a `test_not_updated` record if no co-changed test file exists.

- [ ] **Step 1: Test**

Create `src/test_pair.zig`:

```zig
//! Maps source paths to expected test paths per language convention.

const std = @import("std");

pub fn expectedTestPath(gpa: std.mem.Allocator, src: []const u8) ![]const ?[]const u8 {
    // Returns up to 3 candidates; null entries are skipped.
    if (std.mem.endsWith(u8, src, ".go")) {
        const stem = src[0 .. src.len - 3];
        return try makeList(gpa, &.{try std.fmt.allocPrint(gpa, "{s}_test.go", .{stem})});
    }
    if (std.mem.endsWith(u8, src, ".ts") or std.mem.endsWith(u8, src, ".js") or
        std.mem.endsWith(u8, src, ".tsx") or std.mem.endsWith(u8, src, ".mjs"))
    {
        const dot = std.mem.lastIndexOfScalar(u8, src, '.').?;
        const stem = src[0..dot];
        const ext = src[dot..];
        return try makeList(gpa, &.{
            try std.fmt.allocPrint(gpa, "{s}.test{s}", .{ stem, ext }),
            try std.fmt.allocPrint(gpa, "{s}.spec{s}", .{ stem, ext }),
        });
    }
    if (std.mem.endsWith(u8, src, ".dart")) {
        // lib/foo.dart -> test/foo_test.dart
        if (std.mem.startsWith(u8, src, "lib/")) {
            const stem = src["lib/".len .. src.len - ".dart".len];
            return try makeList(gpa, &.{try std.fmt.allocPrint(gpa, "test/{s}_test.dart", .{stem})});
        }
    }
    return try makeList(gpa, &.{});
}

fn makeList(gpa: std.mem.Allocator, items: []const ?[]const u8) ![]const ?[]const u8 {
    return try gpa.dupe(?[]const u8, items);
}

pub fn isTestPath(p: []const u8) bool {
    return std.mem.indexOf(u8, p, "_test.") != null
        or std.mem.indexOf(u8, p, ".test.") != null
        or std.mem.indexOf(u8, p, ".spec.") != null
        or std.mem.startsWith(u8, p, "test/")
        or std.mem.indexOf(u8, p, "/__tests__/") != null;
}

test "Go test pairing" {
    const gpa = std.testing.allocator;
    const out = try expectedTestPath(gpa, "src/auth.go");
    defer {
        for (out) |o| if (o) |s| gpa.free(s);
        gpa.free(out);
    }
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("src/auth_test.go", out[0].?);
}

test "TS test pairing" {
    const gpa = std.testing.allocator;
    const out = try expectedTestPath(gpa, "src/foo.ts");
    defer {
        for (out) |o| if (o) |s| gpa.free(s);
        gpa.free(out);
    }
    try std.testing.expect(out.len >= 1);
}

test "isTestPath" {
    try std.testing.expect(isTestPath("foo_test.go"));
    try std.testing.expect(isTestPath("a/b/foo.test.ts"));
    try std.testing.expect(!isTestPath("foo.go"));
}
```

- [ ] **Step 2: Wire into review.zig multi-file driver (Task 3.5)**

(Skipped here; this task only adds the helper module and tests.)

Run: `zig build test`. Expected: PASS.

---

### Task 3.4: `src/symbols.zig` — minimal symbol table for callsites

**Files:**
- Create: `src/symbols.zig`
- Modify: `src/review.zig`

Build only when at least one `signature_change` exists. Walks both trees once; for each statement-level node, scans content for identifier references matching changed symbol names. Emits `callsites: [{path, line}]` on the change record for the parent fn.

This is a minimal implementation; no scope-aware resolution.

- [ ] **Step 1: Test**

```zig
const std = @import("std");
const ast = @import("ast.zig");
const differ = @import("differ.zig");

pub const Callsite = struct { path: []const u8, line: u32 };

/// Scan all `*_stmt` content slices in `tree` for occurrences of `name` as
/// a word. Append one Callsite per statement that contains it.
pub fn findCallsites(
    gpa: std.mem.Allocator,
    tree: *ast.Tree,
    name: []const u8,
    out: *std.ArrayList(Callsite),
) !void {
    const kinds = tree.nodes.items(.kind);
    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const k = kinds[i];
        const is_stmt = k == .rust_stmt or k == .go_stmt or k == .zig_stmt
            or k == .dart_stmt or k == .js_stmt or k == .ts_stmt;
        if (!is_stmt) continue;
        const slice = tree.contentSlice(i);
        if (containsWord(slice, name)) {
            const lc = tree.lineCol(i);
            try out.append(gpa, .{ .path = tree.path, .line = lc.line });
        }
    }
}

fn containsWord(haystack: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!std.mem.eql(u8, haystack[i .. i + needle.len], needle)) continue;
        const left_ok = i == 0 or !isIdent(haystack[i - 1]);
        const right_ok = i + needle.len == haystack.len or !isIdent(haystack[i + needle.len]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

fn isIdent(c: u8) bool { return std.ascii.isAlphanumeric(c) or c == '_'; }

const go_parser = @import("go_parser.zig");

test "findCallsites: finds Add() inside another fn body" {
    const gpa = std.testing.allocator;
    var tree = try go_parser.parse(gpa,
        "package main\nfunc Add(a, b int) int { return a + b }\nfunc Run() { x := Add(1,2) }\n", "x.go");
    defer tree.deinit();

    var sites: std.ArrayList(Callsite) = .empty;
    defer sites.deinit(gpa);
    try findCallsites(gpa, &tree, "Add", &sites);
    try std.testing.expect(sites.items.len >= 1);
}
```

- [ ] **Step 2: Wire into review.zig**

In `ChangeMeta` add `callsites: []const Callsite = &.{};`. In `renderReviewJson`, after sigdiff:

```zig
if (anySignatureChange(metas)) {
    try annotateCallsites(gpa, set, a, b, metas);
}
```

Where `annotateCallsites` invokes `findCallsites` on tree B for each signature_change record using the symbol's name. Cap at 50 sites per change to bound output.

Render in `writeRecord`:

```zig
if (m.callsites.len > 0) {
    try w.writeAll(",\"callsites\":[");
    for (m.callsites, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"path\":");
        try writeJsonString(w, s.path);
        try w.print(",\"line\":{d}}}", .{s.line});
    }
    try w.writeByte(']');
}
```

- [ ] **Step 3: Run**

Run: `zig build test`. Expected: PASS.

---

### Task 3.5: Multi-file driver — `runDiffSet` + test_not_updated emission

**Files:**
- Modify: `src/review.zig`, `src/main.zig:runGit`

Currently `runFilePair` only handles one (a,b). The git mode needs to:
1. Iterate all changed files.
2. Run review per file.
3. Emit a single combined NDJSON: one schema header, all per-file records, single summary, single final block of `test_not_updated` records.

- [ ] **Step 1: Refactor review.zig to expose `Run` context**

```zig
pub const Run = struct {
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    summary: Summary = .{},
    seen_paths: std.StringHashMap(void),

    pub fn init(gpa: std.mem.Allocator, w: *std.Io.Writer) !Run {
        try w.print("{{\"kind\":\"schema\",\"version\":\"{s}\",\"syndiff\":\"{s}\"}}\n", .{ SCHEMA_VERSION, SYNDIFF_VERSION });
        return .{ .gpa = gpa, .writer = w, .seen_paths = .init(gpa) };
    }

    pub fn deinit(self: *Run) void { self.seen_paths.deinit(); }

    pub fn addFilePair(self: *Run, a: *ast.Tree, b: *ast.Tree, set: *differ.DiffSet) !void {
        try self.seen_paths.put(a.path, {});
        try self.seen_paths.put(b.path, {});

        try @import("rename.zig").pairRenames(self.gpa, set, a, b);

        const metas = try self.gpa.alloc(ChangeMeta, set.changes.items.len);
        defer self.gpa.free(metas);
        for (metas) |*m| m.* = .{};

        try annotateScope(self.gpa, set, a, b, metas);
        try annotateKindTag(set, a, b, metas);
        annotateExport(set, a, b, metas);
        try annotateChangeId(set, a, b, metas);
        try annotateLineChurn(self.gpa, set, a, b, metas);
        try annotateSignatureDelta(self.gpa, set, a, b, metas);
        annotateSensitivity(set, a, b, metas);
        try annotateComplexity(self.gpa, set, a, b, metas);
        if (anySignatureChange(metas)) try annotateCallsites(self.gpa, set, a, b, metas);

        for (set.changes.items, metas) |c, m| {
            try writeRecord(self.writer, &c, &m, a, b);
            switch (c.kind) {
                .added => self.summary.counts.added += 1,
                .deleted => self.summary.counts.deleted += 1,
                .modified => self.summary.counts.modified += 1,
                .moved => self.summary.counts.moved += 1,
                .renamed => self.summary.counts.renamed += 1,
            }
            if (m.is_exported) self.summary.exported_changes += 1;
        }
    }

    pub fn finish(self: *Run, all_changed_paths: []const []const u8) !void {
        // Emit test_not_updated records.
        try emitTestPairing(self.gpa, self.writer, all_changed_paths);

        self.summary.files_changed = @intCast(self.seen_paths.count());
        try self.writer.print(
            "{{\"kind\":\"summary\",\"files_changed\":{d}, ...}}\n",
            .{self.summary.files_changed},
        );
    }
};
```

(Sketch — fill in `Summary` rendering with all fields.)

`emitTestPairing` walks `all_changed_paths`, ignores test files, for each non-test source: compute `expectedTestPath`, check membership in `all_changed_paths`; if no candidate matches, emit:

```json
{"kind":"test_not_updated","path":"src/auth.go","reason":"no churn in src/auth_test.go"}
```

- [ ] **Step 2: Modify `src/main.zig:runGit` to use `Run`**

Add a branch in `runGit` for `output == .review_json`:

```zig
if (output == .review_json) {
    var run = try syndiff.review.Run.init(arena, stdout);
    defer run.deinit();
    for (changed) |path| {
        // ... parse a_tree, b_tree, build DiffSet ...
        try run.addFilePair(&a_tree, &b_tree, &set);
    }
    try run.finish(changed);
    try stdout.flush();
    die(stderr, stdout, if (run.summary.totalChanges() > 0) .changes_found else .no_changes);
}
```

Add `Summary.totalChanges` returning sum of all counts.

For the file-pair mode (`runFiles`), keep using `renderReviewJson` (single-file convenience).

- [ ] **Step 3: Snapshot test**

`testdata/review/test_not_updated/src/foo.go` (real path with directory). Use the file-pair mode to fake it; or add a multi-file integration test that runs the binary against a small fixture repo (script under `testdata/review/test_not_updated/run.sh` that creates the repo, commits, runs `--review HEAD~1 HEAD`, diffs against `expected.ndjson`).

- [ ] **Step 4: Run**

Run: `zig build test`. Expected: PASS.

---

### Task 3.6: `--group-by symbol` — collapse stmt-level into parent

**Files:**
- Modify: `src/main.zig` (parseArgs), `src/review.zig`

Optional, off-by-default. When set, statement-level changes (`*_stmt`) are emitted as nested `sub_changes` under their enclosing fn/method record.

- [ ] **Step 1: parseArgs test + flag**

```zig
test "parseArgs: --group-by symbol" {
    const r = parseArgs(&.{ "syndiff", "--review", "--group-by", "symbol" });
    try std.testing.expect(r == .git);
    try std.testing.expect(r.git.common.group_by_symbol);
}
```

Add `group_by_symbol: bool = false` to `CommonOpts`. Parse `--group-by symbol`.

- [ ] **Step 2: Implement grouping in `Run.addFilePair`**

When `group_by_symbol` is set on the run, before emitting records, walk each `*_stmt` change and either: attach it as a child of its parent's record (if the parent is also in the changeset) or emit it standalone (if the parent isn't a change).

Schema addition: `sub_changes: [<change record>...]` on parent records.

- [ ] **Step 3: Snapshot test**

Add a fixture that produces two stmt-level changes inside the same fn; verify with `--group-by symbol` they collapse to one record with `sub_changes` of length 2; without the flag, two top-level stmt records.

- [ ] **Step 4: Run**

Run: `zig build test`. Expected: PASS.

---

### Task 3.7: Performance regression check

**Files:**
- Modify: `src/bench.zig` (or extend existing bench harness)

The bench file already exists. Add a `--review` benchmark that runs the same input through both `--format json` and `--review` and reports the ratio.

- [ ] **Step 1: Add bench cases**

In `src/bench.zig`, find the existing kernel/TS-corpus bench cases. For each, add a parallel run that calls `review.renderReviewJson` instead of `differ.renderJson`. Print both timings and the ratio.

- [ ] **Step 2: Run**

Run: `zig build bench` (or whatever the existing harness invokes — check `build.zig` for the bench step).
Expected: review-mode adds <15% over `--format json`.

If overhead exceeds 15%, profile via `perf` or `samply` and identify the dominant pass. Likely candidates: `annotateScope` allocations (consider arena), `findCallsites` scanning whole files (cap iterations), `signature.extract` running twice for renames (cache results).

---

### Task 3.8: README + schema docs

**Files:**
- Modify: `README.md`
- Confirm: `schemas/review-v1.json` covers all fields added in Phases 2–3

- [ ] **Step 1: Add a "Review mode" section to README**

Document:
- `--review` invocation
- Expected NDJSON shape (link to `schemas/review-v1.json`)
- Out-of-scope (cyclomatic complexity, full project index, LLM summaries — review tool's job)

- [ ] **Step 2: Update the schema**

Ensure all new fields are in `schemas/review-v1.json`:
- `signature_diff` with nested `params_added/removed/changed` shapes
- `sensitivity` (array of strings, enum)
- `complexity_delta` (object with `stmt_a/stmt_b/delta`)
- `callsites` (array of `{path, line}`)
- `sub_changes` (when `--group-by symbol`)
- `test_not_updated` record variant
- `renamed` kind in the change-record `kind` enum
- `summary` extended with `breaking_signature_changes` and `sensitivity_totals`

- [ ] **Step 3: Run schema validator test**

Run: `zig build test 2>&1 | grep schema`
Expected: PASS.

---

### Task 3.9: Phase 3 verification gate

- [ ] **Step 1: Full test run**

Run: `zig build test`
Expected: every suite passes.

- [ ] **Step 2: End-to-end against this repo's history**

Run: `./zig-out/bin/syndiff --review HEAD~1 HEAD | wc -l`
Expected: ≥ 3 lines (schema + ≥1 record + summary), valid NDJSON line-by-line.

Sanity check: `./zig-out/bin/syndiff --review HEAD~1 HEAD | jq -c .` should not error.

- [ ] **Step 3: Goldens still byte-stable**

Run the manual golden check from Task 1.10. Expected: empty diff.

---

## Out of Scope (Defer)

Documented in README; do not implement:
- Cross-file symbol resolution beyond in-diff scope
- Cyclomatic complexity (only stmt-count proxy in v1)
- HTTP/webhook server mode
- LLM-generated summaries inside syndiff
- Bindings for Go/Python/Node — JSON contract is the boundary
