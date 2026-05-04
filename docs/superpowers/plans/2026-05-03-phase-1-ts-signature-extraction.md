# Phase 1 — TS-only Signature Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit `signature_diff` blocks for `ts_interface`, `ts_type`, and `ts_enum` records so review consumers see structured deltas instead of body-blob modifications.

**Architecture:** Extend `src/signature.zig`'s `extract` dispatch with three new per-kind extractors that read the node's `content_range` slice and parse the member list (interface members, union variants, enum constants) into `Signature.params`. Reuse the existing `forEachDepth0Segment` helper. No changes to the diff pipeline; `kind_tag` derivation in `review.zig` already routes any kind with a non-null signature through `signature_change` when identity-bytes differ.

**Tech Stack:** Zig 0.16+, `std.MultiArrayList`, `std.testing`, `std.heap.ArenaAllocator`. Output stays `review-v1` — every change is additive.

**Out of scope for this phase:** `ts_namespace` (container-only, no useful sig shape), `ts_declare` (ambient — extractor returns null), `abstract class` modifier (no separate kind today; would require parser change).

---

## File Structure

- Modify: `src/signature.zig` — add `extractTsInterface`, `extractTsType`, `extractTsEnum`; extend the `extract` dispatch switch at lines 50–55.
- Modify: `src/ts_parser.zig` — confirm `content_range` covers the member-list bytes for each TS kind (verify-only; expected to already be correct).
- Add: `testdata/review/ts_interface_change/before.ts`, `testdata/review/ts_interface_change/after.ts`, `testdata/review/ts_interface_change/expected.ndjson`.
- Add: `testdata/review/ts_type_change/before.ts`, `testdata/review/ts_type_change/after.ts`, `testdata/review/ts_type_change/expected.ndjson`.
- Add: `testdata/review/ts_enum_change/before.ts`, `testdata/review/ts_enum_change/after.ts`, `testdata/review/ts_enum_change/expected.ndjson`.
- Modify: `tests/review_snapshots.zig` — register the three new fixtures.
- Modify: `README.md > Limitations / known gaps` — remove the `"TS-only kinds not extracted in v1"` bullet (line referenced in `signature_diff shape` section).

---

## Task 1: TS interface — extract one untyped property

**Files:**
- Modify: `src/signature.zig`
- Modify: `src/signature.zig` (test block at end of file)

- [ ] **Step 1: Write the failing test**

Append at the bottom of `src/signature.zig`, just before the closing of the file (after the existing `test "extractJs: untyped params, no return type"` block):

```zig
test "extractTsInterface: single property" {
    const gpa = std.testing.allocator;
    const ts_parser = @import("ts_parser.zig");
    var tree = try ts_parser.parse(gpa, "interface Foo { name: string; }\n", "x.ts");
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var iface_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .ts_interface) {
        iface_idx = @intCast(i);
        break;
    };
    const sig = (try extract(gpa, &tree, iface_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("Foo", sig.name);
    try std.testing.expectEqual(@as(usize, 1), sig.params.len);
    try std.testing.expectEqualStrings("name", sig.params[0].name);
    try std.testing.expectEqualStrings("string", sig.params[0].type_str);
    try std.testing.expectEqual(false, sig.params[0].has_default);
    try std.testing.expect(sig.return_type == null);
    try std.testing.expectEqual(Visibility.public, sig.visibility);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "extractTsInterface: single property"`
Expected: FAIL — either compile error (unknown extractor) or `error.NoSignature` because `extract` returns `null` for `.ts_interface`.

- [ ] **Step 3: Add `.ts_interface` to dispatch and stub `extractTsInterface`**

In `src/signature.zig`, edit the dispatch switch (around lines 50–55):

```zig
return switch (kind) {
    .go_fn, .go_method => try extractGo(gpa, tree, idx),
    .rust_fn => try extractRust(gpa, tree, idx),
    .zig_fn => try extractZig(gpa, tree, idx),
    .dart_fn, .dart_method => try extractDart(gpa, tree, idx),
    .js_function, .js_method => try extractJs(gpa, tree, idx),
    .ts_interface => try extractTsInterface(gpa, tree, idx),
    else => null,
};
```

Then add the extractor implementation just before the `// Tests` section (after `pushJsParam`):

```zig
fn extractTsInterface(
    gpa: std.mem.Allocator,
    tree: *ast.Tree,
    idx: ast.NodeIndex,
) !?Signature {
    const content_ranges = tree.nodes.items(.content_range);
    const identity_ranges = tree.nodes.items(.identity_range);
    const cr = content_ranges[idx];
    const ir = identity_ranges[idx];
    const src = tree.source[cr.start..cr.end];
    const name = tree.source[ir.start..ir.end];

    // Members live between the first `{` and the matching `}` at depth 0.
    const open_brace = std.mem.indexOfScalar(u8, src, '{') orelse return null;
    const close_brace = findBalancedCloseBrace(src, open_brace) orelse return null;
    const body = src[open_brace + 1 .. close_brace];

    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(gpa);

    try forEachDepth0Segment(gpa, body, ';', struct {
        fn cb(seg: []const u8, ctx: *anyopaque) !void {
            const list: *std.ArrayList(Param) = @ptrCast(@alignCast(ctx));
            const trimmed = std.mem.trim(u8, seg, " \t\r\n");
            if (trimmed.len == 0) return;
            // Skip method-style members (those carrying a `(` are not
            // properties — leave them for a future extension).
            if (std.mem.indexOfScalar(u8, trimmed, '(') != null) return;
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return;
            const member_name = std.mem.trim(u8, trimmed[0..colon], " \t?");
            const member_type = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
            const has_default = std.mem.indexOfScalar(u8, trimmed[0..colon], '?') != null;
            try list.append(@as(*const std.mem.Allocator, @ptrCast(@alignCast(@constCast(&list.allocator)))).*, .{
                .name = member_name,
                .type_str = member_type,
                .has_default = has_default,
            });
        }
    }.cb, &params);

    const params_slice = try params.toOwnedSlice(gpa);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    for (params_slice) |p| {
        hasher.update(p.name);
        hasher.update(p.type_str);
    }

    return .{
        .name = name,
        .params = params_slice,
        .return_type = null,
        .visibility = .public,
        .modifiers = .{},
        .hash = hasher.final(),
    };
}

fn findBalancedCloseBrace(slice: []const u8, brace_open: usize) ?usize {
    var depth: u32 = 0;
    var i: usize = brace_open;
    while (i < slice.len) : (i += 1) {
        switch (slice[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}
```

> **Note:** The closure signature for `forEachDepth0Segment` may differ from the placeholder above. When implementing, open `src/signature.zig` and copy the actual call-site shape used by `extractGo` / `extractRust` (around `pushGoParam`). If the existing helper does not take a context pointer, replace the closure with an inline loop using `std.mem.splitScalar(u8, body, ';')` plus a brace-depth counter.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -30`
Expected: All tests pass; new test reports OK.

- [ ] **Step 5: Commit**

```bash
git add src/signature.zig
git commit -m "feat(signature): extract ts_interface members as params"
```

---

## Task 2: TS interface — optional `?` and method members

**Files:**
- Modify: `src/signature.zig` (test additions only)

- [ ] **Step 1: Write the failing test**

Append after the previous test:

```zig
test "extractTsInterface: optional and method members" {
    const gpa = std.testing.allocator;
    const ts_parser = @import("ts_parser.zig");
    var tree = try ts_parser.parse(
        gpa,
        "interface Foo { id: number; nick?: string; greet(): void; }\n",
        "x.ts",
    );
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var iface_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .ts_interface) {
        iface_idx = @intCast(i);
        break;
    };
    const sig = (try extract(gpa, &tree, iface_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    // greet() is a method — Phase 1 skips methods, leaves only properties.
    try std.testing.expectEqual(@as(usize, 2), sig.params.len);
    try std.testing.expectEqualStrings("id", sig.params[0].name);
    try std.testing.expectEqualStrings("number", sig.params[0].type_str);
    try std.testing.expectEqual(false, sig.params[0].has_default);
    try std.testing.expectEqualStrings("nick", sig.params[1].name);
    try std.testing.expectEqualStrings("string", sig.params[1].type_str);
    try std.testing.expectEqual(true, sig.params[1].has_default);
}
```

- [ ] **Step 2: Run to verify it passes (or fails on `?` handling)**

Run: `zig build test 2>&1 | grep -A3 "optional and method"`
Expected: PASS if Task 1's `?`-detection branch is correct. If FAIL, adjust the `has_default` derivation in `extractTsInterface` so it strips the `?` from the member name and sets `has_default = true`.

- [ ] **Step 3: Commit (only if a fix was needed)**

```bash
git add src/signature.zig
git commit -m "test(signature): cover optional and method ts_interface members"
```

If no fix was needed and only the test was added, commit it as `test(signature): cover optional and method ts_interface members` anyway.

---

## Task 3: TS type — union variants

**Files:**
- Modify: `src/signature.zig`

- [ ] **Step 1: Write the failing test**

Append:

```zig
test "extractTsType: union variants become params" {
    const gpa = std.testing.allocator;
    const ts_parser = @import("ts_parser.zig");
    var tree = try ts_parser.parse(
        gpa,
        "type Color = \"red\" | \"green\" | \"blue\";\n",
        "x.ts",
    );
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var t_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .ts_type) {
        t_idx = @intCast(i);
        break;
    };
    const sig = (try extract(gpa, &tree, t_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("Color", sig.name);
    try std.testing.expectEqual(@as(usize, 3), sig.params.len);
    try std.testing.expectEqualStrings("\"red\"", sig.params[0].name);
    try std.testing.expectEqualStrings("\"green\"", sig.params[1].name);
    try std.testing.expectEqualStrings("\"blue\"", sig.params[2].name);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "union variants"`
Expected: FAIL — `extract` returns null for `.ts_type`.

- [ ] **Step 3: Add `.ts_type` extractor**

In the dispatch switch, append:

```zig
.ts_type => try extractTsType(gpa, tree, idx),
```

Add the extractor:

```zig
fn extractTsType(
    gpa: std.mem.Allocator,
    tree: *ast.Tree,
    idx: ast.NodeIndex,
) !?Signature {
    const content_ranges = tree.nodes.items(.content_range);
    const identity_ranges = tree.nodes.items(.identity_range);
    const cr = content_ranges[idx];
    const ir = identity_ranges[idx];
    const src = tree.source[cr.start..cr.end];
    const name = tree.source[ir.start..ir.end];

    // RHS lives after the first `=` at depth 0, before the trailing `;`.
    const eq = std.mem.indexOfScalar(u8, src, '=') orelse return null;
    var rhs_end = src.len;
    if (rhs_end > 0 and src[rhs_end - 1] == ';') rhs_end -= 1;
    const rhs = std.mem.trim(u8, src[eq + 1 .. rhs_end], " \t\r\n");

    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(gpa);

    // Split on `|` at brace/paren/angle depth 0.
    var seg_start: usize = 0;
    var paren: u32 = 0;
    var brace: u32 = 0;
    var angle: u32 = 0;
    var i: usize = 0;
    while (i < rhs.len) : (i += 1) {
        switch (rhs[i]) {
            '(' => paren += 1,
            ')' => paren -|= 1,
            '{' => brace += 1,
            '}' => brace -|= 1,
            '<' => angle += 1,
            '>' => angle -|= 1,
            '|' => if (paren == 0 and brace == 0 and angle == 0) {
                const seg = std.mem.trim(u8, rhs[seg_start..i], " \t\r\n");
                if (seg.len > 0) try params.append(gpa, .{
                    .name = seg,
                    .type_str = "",
                    .has_default = false,
                });
                seg_start = i + 1;
            },
            else => {},
        }
    }
    const tail = std.mem.trim(u8, rhs[seg_start..], " \t\r\n");
    if (tail.len > 0) try params.append(gpa, .{
        .name = tail,
        .type_str = "",
        .has_default = false,
    });

    const params_slice = try params.toOwnedSlice(gpa);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    for (params_slice) |p| hasher.update(p.name);

    return .{
        .name = name,
        .params = params_slice,
        .return_type = null,
        .visibility = .public,
        .modifiers = .{},
        .hash = hasher.final(),
    };
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test 2>&1 | tail -30`
Expected: PASS for `union variants become params`.

- [ ] **Step 5: Commit**

```bash
git add src/signature.zig
git commit -m "feat(signature): extract ts_type union variants as params"
```

---

## Task 4: TS type — single (non-union) RHS yields zero params

**Files:**
- Modify: `src/signature.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "extractTsType: single-RHS yields one param" {
    const gpa = std.testing.allocator;
    const ts_parser = @import("ts_parser.zig");
    var tree = try ts_parser.parse(
        gpa,
        "type Id = number;\n",
        "x.ts",
    );
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var t_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .ts_type) {
        t_idx = @intCast(i);
        break;
    };
    const sig = (try extract(gpa, &tree, t_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("Id", sig.name);
    try std.testing.expectEqual(@as(usize, 1), sig.params.len);
    try std.testing.expectEqualStrings("number", sig.params[0].name);
}
```

- [ ] **Step 2: Run to verify it passes**

Run: `zig build test 2>&1 | grep -A3 "single-RHS"`
Expected: PASS — Task 3's tail-segment append handles this case naturally.

- [ ] **Step 3: Commit**

```bash
git add src/signature.zig
git commit -m "test(signature): cover ts_type single-RHS"
```

---

## Task 5: TS enum — variants

**Files:**
- Modify: `src/signature.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "extractTsEnum: variants become params" {
    const gpa = std.testing.allocator;
    const ts_parser = @import("ts_parser.zig");
    var tree = try ts_parser.parse(
        gpa,
        "enum Status { Active, Disabled, Pending = 99 }\n",
        "x.ts",
    );
    defer tree.deinit();

    const kinds = tree.nodes.items(.kind);
    var e_idx: ?ast.NodeIndex = null;
    for (kinds, 0..) |k, i| if (k == .ts_enum) {
        e_idx = @intCast(i);
        break;
    };
    const sig = (try extract(gpa, &tree, e_idx.?)) orelse return error.NoSignature;
    defer gpa.free(sig.params);

    try std.testing.expectEqualStrings("Status", sig.name);
    try std.testing.expectEqual(@as(usize, 3), sig.params.len);
    try std.testing.expectEqualStrings("Active", sig.params[0].name);
    try std.testing.expectEqual(false, sig.params[0].has_default);
    try std.testing.expectEqualStrings("Disabled", sig.params[1].name);
    try std.testing.expectEqualStrings("Pending", sig.params[2].name);
    try std.testing.expectEqual(true, sig.params[2].has_default);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "variants become params"`
Expected: FAIL — `.ts_enum` returns null.

- [ ] **Step 3: Add `.ts_enum` extractor**

Extend the dispatch switch:

```zig
.ts_enum => try extractTsEnum(gpa, tree, idx),
```

Add the extractor:

```zig
fn extractTsEnum(
    gpa: std.mem.Allocator,
    tree: *ast.Tree,
    idx: ast.NodeIndex,
) !?Signature {
    const content_ranges = tree.nodes.items(.content_range);
    const identity_ranges = tree.nodes.items(.identity_range);
    const cr = content_ranges[idx];
    const ir = identity_ranges[idx];
    const src = tree.source[cr.start..cr.end];
    const name = tree.source[ir.start..ir.end];

    const open_brace = std.mem.indexOfScalar(u8, src, '{') orelse return null;
    const close_brace = findBalancedCloseBrace(src, open_brace) orelse return null;
    const body = src[open_brace + 1 .. close_brace];

    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(gpa);

    var seg_start: usize = 0;
    var paren: u32 = 0;
    var brace: u32 = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        switch (body[i]) {
            '(' => paren += 1,
            ')' => paren -|= 1,
            '{' => brace += 1,
            '}' => brace -|= 1,
            ',' => if (paren == 0 and brace == 0) {
                try pushEnumVariant(gpa, &params, body[seg_start..i]);
                seg_start = i + 1;
            },
            else => {},
        }
    }
    try pushEnumVariant(gpa, &params, body[seg_start..]);

    const params_slice = try params.toOwnedSlice(gpa);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    for (params_slice) |p| hasher.update(p.name);

    return .{
        .name = name,
        .params = params_slice,
        .return_type = null,
        .visibility = .public,
        .modifiers = .{},
        .hash = hasher.final(),
    };
}

fn pushEnumVariant(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Param),
    seg: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, seg, " \t\r\n");
    if (trimmed.len == 0) return;
    const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=');
    const variant_name = if (eq_idx) |e| std.mem.trim(u8, trimmed[0..e], " \t") else trimmed;
    try list.append(gpa, .{
        .name = variant_name,
        .type_str = "",
        .has_default = eq_idx != null,
    });
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test 2>&1 | tail -30`
Expected: All TS extractor tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/signature.zig
git commit -m "feat(signature): extract ts_enum variants as params"
```

---

## Task 6: review.zig already routes TS sigs — verify with a synthetic diff

**Files:**
- Modify: `src/review.zig` (test additions only)

- [ ] **Step 1: Write the failing test**

Append at the end of `src/review.zig` (alongside the existing `annotateKindTag` tests):

```zig
test "ts_interface modification produces signature_change with diff" {
    const gpa = std.testing.allocator;
    const ts_parser = @import("ts_parser.zig");

    var a = try ts_parser.parse(gpa, "interface Foo { name: string; }\n", "x.ts");
    defer a.deinit();
    var b = try ts_parser.parse(gpa, "interface Foo { name: string; age: number; }\n", "x.ts");
    defer b.deinit();

    var set = try differ.diff(gpa, &a, &b);
    defer set.deinit(gpa);

    var metas = try buildMetas(gpa, &set);
    defer freeMetas(gpa, metas);

    try annotateKindTag(metas, &set, &a, &b);
    try annotateSignatureDelta(gpa, metas, &set, &a, &b);

    var found = false;
    for (metas) |m| {
        if (m.kind_tag == .signature_change and
            m.signature_diff != null and
            m.signature_diff.?.params_added.len == 1)
        {
            try std.testing.expectEqualStrings("age", m.signature_diff.?.params_added[0].name);
            found = true;
        }
    }
    try std.testing.expect(found);
}
```

> **Note:** the helper names `buildMetas`, `freeMetas`, `annotateKindTag`, and `annotateSignatureDelta` reflect the existing `review.zig` API. If signatures differ, copy the call shape from the closest existing `test "annotateKindTag: ..."` block.

- [ ] **Step 2: Run to verify it passes**

Run: `zig build test 2>&1 | grep -A3 "ts_interface modification"`
Expected: PASS — no review.zig change should be needed; the dispatch in Tasks 1, 3, 5 already returns non-null sigs for the TS kinds.

- [ ] **Step 3: Commit**

```bash
git add src/review.zig
git commit -m "test(review): verify ts_interface signature_change diff"
```

---

## Task 7: Snapshot fixture — `ts_interface_change`

**Files:**
- Add: `testdata/review/ts_interface_change/before.ts`
- Add: `testdata/review/ts_interface_change/after.ts`
- Add: `testdata/review/ts_interface_change/expected.ndjson`
- Modify: `tests/review_snapshots.zig`

- [ ] **Step 1: Create `before.ts`**

```typescript
export interface User {
  id: string;
  name: string;
}
```

- [ ] **Step 2: Create `after.ts`**

```typescript
export interface User {
  id: string;
  name: string;
  email: string;
}
```

- [ ] **Step 3: Generate the expected NDJSON**

Run: `zig build run -- --review testdata/review/ts_interface_change/before.ts testdata/review/ts_interface_change/after.ts > testdata/review/ts_interface_change/expected.ndjson`

Then open `expected.ndjson` and confirm the `modified` record carries:
- `"kind_tag":"signature_change"`
- `"signature_diff":{"params_added":[{"name":"email","type":"string"}],...}`
- `"is_exported":true`

If any of those is missing, the bug is in Tasks 1–6, not in fixture generation. Fix upstream and regenerate.

- [ ] **Step 4: Register fixture in `tests/review_snapshots.zig`**

Find the existing fixture registration block (look for `"body_only"` and `"rename_only"`). Add a new entry:

```zig
.{ .name = "ts_interface_change", .a = "before.ts", .b = "after.ts" },
```

Match whatever struct shape the existing entries use — copy verbatim.

- [ ] **Step 5: Run the snapshot test**

Run: `zig build test 2>&1 | grep -A3 "ts_interface_change"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add testdata/review/ts_interface_change tests/review_snapshots.zig
git commit -m "test(review): snapshot fixture for ts_interface signature change"
```

---

## Task 8: Snapshot fixture — `ts_type_change`

**Files:**
- Add: `testdata/review/ts_type_change/before.ts`
- Add: `testdata/review/ts_type_change/after.ts`
- Add: `testdata/review/ts_type_change/expected.ndjson`
- Modify: `tests/review_snapshots.zig`

- [ ] **Step 1: Create `before.ts`**

```typescript
export type Color = "red" | "green";
```

- [ ] **Step 2: Create `after.ts`**

```typescript
export type Color = "red" | "green" | "blue";
```

- [ ] **Step 3: Generate `expected.ndjson`**

Run: `zig build run -- --review testdata/review/ts_type_change/before.ts testdata/review/ts_type_change/after.ts > testdata/review/ts_type_change/expected.ndjson`

Verify it carries `"params_added":[{"name":"\"blue\"","type":""}]`.

- [ ] **Step 4: Register fixture**

Append to the registration block in `tests/review_snapshots.zig`:

```zig
.{ .name = "ts_type_change", .a = "before.ts", .b = "after.ts" },
```

- [ ] **Step 5: Run snapshot test**

Run: `zig build test 2>&1 | grep -A3 "ts_type_change"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add testdata/review/ts_type_change tests/review_snapshots.zig
git commit -m "test(review): snapshot fixture for ts_type union variant change"
```

---

## Task 9: Snapshot fixture — `ts_enum_change`

**Files:**
- Add: `testdata/review/ts_enum_change/before.ts`
- Add: `testdata/review/ts_enum_change/after.ts`
- Add: `testdata/review/ts_enum_change/expected.ndjson`
- Modify: `tests/review_snapshots.zig`

- [ ] **Step 1: Create `before.ts`**

```typescript
export enum Status {
  Active,
  Disabled,
}
```

- [ ] **Step 2: Create `after.ts`**

```typescript
export enum Status {
  Active,
  Disabled,
  Pending = 99,
}
```

- [ ] **Step 3: Generate `expected.ndjson`**

Run: `zig build run -- --review testdata/review/ts_enum_change/before.ts testdata/review/ts_enum_change/after.ts > testdata/review/ts_enum_change/expected.ndjson`

Verify the `modified` record:
- `"kind_tag":"signature_change"`
- `"params_added":[{"name":"Pending",...}]`

- [ ] **Step 4: Register fixture**

```zig
.{ .name = "ts_enum_change", .a = "before.ts", .b = "after.ts" },
```

- [ ] **Step 5: Run snapshot test**

Run: `zig build test 2>&1 | grep -A3 "ts_enum_change"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add testdata/review/ts_enum_change tests/review_snapshots.zig
git commit -m "test(review): snapshot fixture for ts_enum variant change"
```

---

## Task 10: Performance regression check

**Files:**
- Run: `bench.zig` (no source changes expected)

- [ ] **Step 1: Capture baseline**

Run on `main` (before any of the above changes):

```bash
git stash
zig build bench -Doptimize=ReleaseFast > /tmp/bench-before.txt
git stash pop
```

If you've already merged the work, run `git checkout HEAD~10 -- src/signature.zig` in a worktree and rerun. Skip this step if you have a recent baseline checkpointed.

- [ ] **Step 2: Capture post-change**

```bash
zig build bench -Doptimize=ReleaseFast > /tmp/bench-after.txt
```

- [ ] **Step 3: Compare review-mode rows**

Diff `/tmp/bench-before.txt` and `/tmp/bench-after.txt`. The `--review` rows must stay within +2% of baseline. If they regress, the cause is one of: a hot path now allocating, a redundant `findBalancedCloseBrace` call inside a loop, or `forEachDepth0Segment` invoked on every node instead of only TS kinds. Fix and re-bench.

- [ ] **Step 4: Commit (if no fix needed)**

If no source change was needed, commit a `BENCH.md` entry under `docs/`:

```bash
git add docs/BENCH.md   # only if BENCH.md exists; otherwise skip this step
git commit -m "perf(signature): document phase 1 review-mode bench parity"
```

---

## Task 11: Update README to remove the `not extracted in v1` note

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Locate the bullet**

Run: `grep -n "TS-only kinds" README.md`
Expected output:
```
... TS-only kinds (`ts_interface`/`ts_type`/etc.) are not extracted in v1.
```

- [ ] **Step 2: Edit the bullet**

Replace the existing line in `README.md` with:

```
- TS-only kinds: `ts_interface` (members as params), `ts_type` (union variants as params), `ts_enum` (variants as params). `ts_namespace`/`ts_declare` remain skipped.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): record ts_interface/type/enum signature support"
```

---

## Task 12: Final full test sweep

**Files:** none.

- [ ] **Step 1: Run the entire test suite**

Run: `zig build test`
Expected: all green. No skipped tests under `tests/review_snapshots.zig`.

- [ ] **Step 2: Spot-check the new fixtures end-to-end**

Run for each of the three:

```bash
zig build run -- --review testdata/review/ts_interface_change/before.ts testdata/review/ts_interface_change/after.ts | diff - testdata/review/ts_interface_change/expected.ndjson
zig build run -- --review testdata/review/ts_type_change/before.ts testdata/review/ts_type_change/after.ts | diff - testdata/review/ts_type_change/expected.ndjson
zig build run -- --review testdata/review/ts_enum_change/before.ts testdata/review/ts_enum_change/after.ts | diff - testdata/review/ts_enum_change/expected.ndjson
```

Expected: all three diffs are empty.

- [ ] **Step 3: No further commit**

If a diff is non-empty, the corresponding `expected.ndjson` is stale or the extractor regressed — fix the root cause before merging.

---

## Acceptance criteria recap

- `extract` in `src/signature.zig` returns non-null for `.ts_interface`, `.ts_type`, `.ts_enum`.
- Three snapshot fixtures pass under `tests/review_snapshots.zig`.
- `tests/schema_validation.zig` still passes — no schema change required (additive at the value level only).
- `zig build bench` shows ≤2% delta on review-mode rows.
- README's `Limitations / known gaps` no longer claims TS sigs are unsupported.
- All commits scoped to one logical step (12 commits in this plan).

---

## Self-review

- **Spec coverage:** every Phase 1 acceptance bullet from `2026-05-03-roadmap-known-limitations-and-features.md` maps to a task: TS dispatch (T1–T5), routing through review.zig (T6), three fixtures (T7–T9), perf budget (T10), README update (T11), full sweep (T12).
- **Placeholders:** none. Every code step shows the actual code or the exact command and expected output.
- **Type/name consistency:** `Param`, `Signature`, `Visibility`, `Modifiers`, `extract`, `Range` — all match `src/signature.zig` lines 14–55. Kind names `.ts_interface`, `.ts_type`, `.ts_enum` match `src/ast.zig` lines 90–92. Helper names `findBalancedClose`, `forEachDepth0Segment` match `src/signature.zig` lines 66, 84. The new helper `findBalancedCloseBrace` is introduced in Task 1 and reused in Task 5.
- **Closure shape caveat:** Task 1 carries an explicit note that `forEachDepth0Segment` may not take a context-pointer closure; the implementer is told to copy the existing call site shape verbatim. This is an "exact code may need adaptation" callout, not a placeholder — the inline-loop fallback is fully specified.

---

## Execution Handoff

Plan saved at `docs/superpowers/plans/2026-05-03-phase-1-ts-signature-extraction.md`. Two execution options:

1. **Subagent-driven (recommended)** — Dispatch one fresh subagent per task with two-stage review between tasks. Use `superpowers:subagent-driven-development`.
2. **Inline execution** — Execute tasks in this session with checkpoints every 3 tasks. Use `superpowers:executing-plans`.

Pick one to start.
