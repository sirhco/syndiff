# SynDiff — Known Limitations & Deferred Features Roadmap

> **For agentic workers:** This document is a **roadmap**, not a TDD execution plan. Each phase below is a self-contained subsystem that should get its own focused plan (via `superpowers:writing-plans`) before implementation. The roadmap exists to prioritize, scope, and coordinate the phases.

**Goal:** Close every documented gap in `README.md > Limitations / known gaps` and every deferred item in `README.md > Review mode > Out of scope`, plus a few latent issues surfaced during this audit.

**Why a roadmap, not one plan:** The work spans 11 independent subsystems (per-language parsers, schema infra, review-mode extensions, hashing, differ). Each subsystem ships independently and has its own test surface. Bundling them into one plan would create a 1500-line document full of unrelated context and would block partial merges. Each phase below is sized for a single focused plan.

**Tech Stack:** Zig 0.16+, `std.MultiArrayList`, `std.heap.ArenaAllocator`, `std.hash.Wyhash`, draft-07 JSON Schema, NDJSON, git CLI.

**Source-of-truth references:**
- Parser limitations: `README.md:643-668`
- Deferred review-mode items: `README.md:487-495`
- Schema validation gap: `tests/schema_validation.zig:1-30`, `README.md:453`
- Architecture: `README.md > Architecture` and `src/ast.zig:1-100`

---

## How to use this roadmap

1. Pick the highest-priority phase the team can afford this iteration.
2. Run `/superpowers writing-plans` with that phase as the spec.
3. Author a per-phase plan at `docs/superpowers/plans/YYYY-MM-DD-<phase-slug>.md` containing the bite-sized TDD steps.
4. Execute via `superpowers:subagent-driven-development` or `superpowers:executing-plans`.
5. Tick the phase off in this roadmap when its plan is merged.

Each phase below carries:
- **Goal** — one-sentence outcome
- **Why** — user-visible impact
- **Files** — exact paths the work touches
- **Acceptance criteria** — observable conditions that mean it's done
- **Test surface** — where the new tests live
- **Sizing** — S (≤1d), M (1–3d), L (3–7d)
- **Risk** — possible regressions

---

## Priority order (recommended)

| # | Phase | Sizing | Risk | Rationale |
|---|-------|:------:|:----:|-----------|
| 1 | TS-only signature extraction (`ts_interface`/`ts_type`/`ts_enum`) | M | low | Closes the largest review-v1 gap; review consumers see TS today and get nothing back. |
| 2 | Real JSON Schema validation in CI ✅ | S | low | Cheap, prevents schema/fixture drift, unblocks safe additive changes to `review-v1`. Plan: `2026-05-03-phase-2-real-schema-validation.md`. |
| 3 | Hash-collision detection (warn instead of silent overwrite) ✅ | S | low | Currently silent data loss on collision. One-line fix + counter + test. Plan: `2026-05-03-phase-3-hash-collision-detection.md`. |
| 4 | Rust `mod {}` body recursion ✅ | M | medium | Largest functional Rust gap; bodies inside `mod{}` are opaque. Plan: `2026-05-03-phase-4-rust-mod-body-recursion.md`. Identity shift documented in README. |
| 5 | Go multi-name `var x, y = ...` per-name nodes | S | low | Misses identity matches today. |
| 6 | Cyclomatic complexity (real, not stmt-count) | M | low | Replaces stmt-count proxy with branch-count. Per-language. |
| 7 | YAML flow style + anchors/aliases + folded scalars | L | high | Three sub-features; consider splitting further. |
| 8 | Dart `${...}` string-interpolation recursion | M | medium | Pathological-input correctness. |
| 9 | JS regex/division: token-stream–based disambiguation | M | medium | Replace heuristic with a real lexer state machine. |
| 10 | TSX JSX vs generic disambiguation | M | high | Hardest parsing problem in the codebase; needs lookahead heuristics. |
| 11 | MOVED-in-cascading-insert recovery | M | medium | Lost signal in real refactors that re-order under a modified parent. |

> Order is a recommendation. Items 1–3 deliberately group cheap, high-leverage work that unblocks downstream consumers without risking parser regressions.

---

## Phase 1 — TS-only signature extraction

**Goal:** Emit `signature_diff` for `ts_interface`, `ts_type`, `ts_enum`, `ts_namespace`, and `abstract class` records.

**Why:** README documents these as deliberately not extracted in v1: `"TS-only kinds (ts_interface/ts_type/etc.) are not extracted in v1."` Review consumers see TS files in every JS/TS shop. Without sigs, all TS interface/type changes look like undifferentiated body changes.

**Files:**
- Modify: `src/signature.zig` (add per-kind extractors)
- Modify: `src/ts_parser.zig` (ensure `identity_range`/`content_range` cover the relevant slices)
- Modify: `schemas/review-v1.json` (additive — new `kind_tag` values if needed; otherwise no schema change)
- Add: `testdata/review/ts_signatures/before.ts`, `after.ts`, `expected.ndjson`
- Modify: `tests/review_snapshots.zig` (register the new fixture)

**Acceptance criteria:**
- Adding/removing/renaming a property on a `ts_interface` produces a `signature_diff` block with `params_added` / `params_removed` / `params_changed` populated (interface members modeled as the param list).
- Adding a discriminant to a `ts_type = A | B` produces `params_changed`.
- Adding a variant to a `ts_enum` produces `params_added`.
- Existing JS/TS body-only fixtures stay byte-identical (no regressions in `tests/review_snapshots.zig`).
- Schema additive change OR no change — existing `review-v1` consumers continue to validate.

**Test surface:** new fixtures under `testdata/review/ts_signatures/` plus snapshot assertions in `tests/review_snapshots.zig`. Performance must stay within the existing `<15%` review-overhead budget per `bench.zig`.

**Sizing:** M  
**Risk:** low — purely additive, gated by `kind` switch in `signature.zig`.

---

## Phase 2 — Real JSON Schema validation in CI

**Goal:** Replace the substring smoke check in `tests/schema_validation.zig` with a draft-07 validator run against every `expected.ndjson` fixture.

**Why:** README states `"full schema validation is deferred to downstream consumers."` That gap means the fixture files can drift from `schemas/review-v1.json` and the test suite stays green. Cheap to fix; high CI value.

**Files:**
- Modify: `tests/schema_validation.zig`
- Possibly add: `vendor/json-schema/` (if a Zig implementation is vendored) OR `build.zig` step to invoke a host-side validator (e.g., `ajv-cli` via Node) gated behind a build flag.
- Add: a fixture for every record kind under `testdata/review/<scenario>/expected.ndjson` if any kinds lack one today.

**Acceptance criteria:**
- Every `expected.ndjson` fixture validates line-by-line against `schemas/review-v1.json`.
- A fixture that violates the schema fails CI with a precise pointer (`line N, /properties/X: expected boolean`).
- The validator runs as part of `zig build test` — no external network/install needed for `cargo`/`go`-equivalent installs (vendoring preferred).
- A deliberate mutation (e.g., flip `is_exported` to a string) reproduces the failure — proves the assertion is real, not no-op.

**Decision point in the per-phase plan:** vendor a Zig validator vs. shell out to a host validator. Vendoring keeps `zig build test` self-contained.

**Sizing:** S–M  
**Risk:** low.

---

## Phase 3 — Hash-collision detection

**Goal:** Detect identity-hash collisions in `differ.zig` and either (a) warn-and-continue with a counter in the summary or (b) error and refuse to render.

**Why:** README: `"64-bit identity hash; first-write-wins on collision. Astronomically rare with parent-composed identity."` Astronomically rare ≠ never; current behavior silently drops one of two colliding nodes from cross-file matching. Adding a counter is one extra map lookup at insert time.

**Files:**
- Modify: `src/differ.zig` — the per-tree `std.AutoHashMap(u64, NodeIndex)` insertion site
- Modify: `src/review.zig` — emit `"hash_collisions": N` into the summary record (additive schema change → still `review-v1`)
- Modify: `schemas/review-v1.json` — add optional `hash_collisions: integer >= 0` to summary
- Add: `tests/hash_collision.zig` — synthetic collision test using a hand-crafted `Tree`

**Acceptance criteria:**
- A constructed two-node tree with identical `identity_hash` values increments `hash_collisions` to 1 and both nodes still appear in the diff stream (no silent drop).
- Existing fixtures emit `"hash_collisions": 0` (or omit the key when 0; pick one and document).
- Schema change is additive — existing consumers unaffected.

**Sizing:** S  
**Risk:** low.

---

## Phase 4 — Rust `mod {}` body recursion

**Goal:** Recurse into `mod foo { ... }` bodies and emit per-item children (`rust_fn`, `rust_struct`, etc.) just like file-scope.

**Why:** README: `"bodies inside mod {} blocks still skip recursion."` Real Rust codebases nest most non-`lib.rs`/`main.rs` items inside `mod` blocks. Today changes there flatten to a single `rust_mod` MODIFIED record.

**Files:**
- Modify: `src/rust_parser.zig` — at the `parseNamedBraced(.rust_mod, ...)` call site (~line 363 per audit grep), call into the existing top-level decl loop with `stop_at_close_brace=true` instead of treating the body as opaque.
- Modify: `src/ast.zig` if a new `rust_mod_inner` shape is required (likely not — reuse existing kinds with `parent_idx` pointing at the mod node).
- Add: `testdata/review/rust_mod/before.rs`, `after.rs`, `expected.ndjson`.

**Acceptance criteria:**
- Adding a `fn` inside `mod foo {}` emits a `rust_fn` ADDED record under `pkg::foo::<fn>`.
- Modifying a body inside the nested `fn` emits a `rust_fn` MODIFIED with `kind_tag` correct.
- Trait body recursion is **explicitly out of scope for this phase** — separate phase if/when prioritized.
- All existing Rust fixtures stay byte-identical.

**Sizing:** M  
**Risk:** medium — recursion changes parent-identity composition; identity hashes for previously top-level-equivalent decls now differ. Must verify cross-version stability is documented.

---

## Phase 5 — Go multi-name `var x, y = ...` per-name nodes

**Goal:** Split `var x, y, z = expr1, expr2, expr3` into three `go_var` nodes, one per name.

**Why:** README: `"multi-name var x, y = 1, 2 emits one node with the first name as identity."` Cross-file identity matching loses `y`/`z` entirely.

**Files:**
- Modify: `src/go_parser.zig` — name-extractor in the grouped-decl walk (audit grep showed extractor around lines 226–266).
- Add: `testdata/review/go_multivar/before.go`, `after.go`, `expected.ndjson`.

**Acceptance criteria:**
- Source `var x, y = 1, 2` produces two `go_var` nodes with identities `pkg.x` and `pkg.y`.
- Renaming `y` → `yy` produces a paired `renamed` record (Tier 3 rename pairing).
- Existing single-name `var x = 1` fixtures unaffected.

**Sizing:** S  
**Risk:** low.

---

## Phase 6 — Cyclomatic complexity (real)

**Goal:** Replace the `stmt_a`/`stmt_b`/`delta` stmt-count proxy with a true cyclomatic count (decision-point count + 1) per-language.

**Why:** README out-of-scope: `"Cyclomatic complexity (v1 ships only the stmt-count proxy)."` Stmt count over-counts pure straight-line growth and under-counts dense branching.

**Files:**
- Add: `src/complexity.zig` — per-`Kind` decision-point counter dispatch.
- Modify: `src/review.zig` — replace stmt-count call site with `complexity.count(tree, idx)`.
- Modify: `schemas/review-v1.json` — `complexity_delta.method: "stmt_count" | "cyclomatic"` (additive enum) **OR** rev to `review-v2` if breaking.
- Add: `testdata/review/complexity/<lang>/before.<ext>`, `after.<ext>`, `expected.ndjson`.

**Decision point:** preserve the stmt-count proxy as an opt-out (`--complexity=stmt_count`) for back-compat or hard-cut to cyclomatic and bump to `review-v2`. Document in the per-phase plan.

**Acceptance criteria:**
- Adding an `if` inside a Go function increments cyclomatic by 1.
- Adding a straight-line statement increments cyclomatic by 0 (proxy would have changed).
- All five sig-supported languages (Go, Rust, Zig, Dart, JS/TS) emit a non-null `complexity_delta`.
- Performance budget: ≤2% additional overhead per `zig build bench`.

**Sizing:** M  
**Risk:** low — additive, gated.

---

## Phase 7 — YAML flow style + anchors/aliases + folded scalars

**Goal:** Extend `yaml_parser.zig` to recognize `{...}` / `[...]` flow style, `&anchor`/`*alias`, and `>`/`|` folded/literal block scalars.

**Why:** README: `"YAML: subset only — no flow style, no anchors/aliases, no folded scalars."` Real-world `compose.yml` / `kustomize` / Helm files use all three.

**Files:**
- Modify: `src/yaml_parser.zig`.
- Possibly add: `src/yaml_anchor_table.zig` for the alias resolution pass.
- Add: `testdata/review/yaml_flow/`, `testdata/review/yaml_anchors/`, `testdata/review/yaml_folded/` fixture sets.

**Decision point in the per-phase plan:** split into three sub-phases (flow / anchors / folded). Each is independently shippable.

**Acceptance criteria (per sub-feature):**
- Flow: `{a: 1, b: 2}` parses identically to its block-style equivalent.
- Anchors/aliases: `*alias` resolves to the same `identity_hash` as the anchor target; modifying the anchor surfaces a single MODIFIED record on the anchor node, not two.
- Folded: `>`/`|` content survives round-trip via the existing `content_range`.
- Tab indentation continues to be rejected (no scope creep).

**Sizing:** L (split into 3×M)  
**Risk:** high — YAML edge cases are infamous; allocate buffer.

---

## Phase 8 — Dart `${...}` string-interpolation recursion

**Goal:** Recurse into `${expr}` as a sub-expression so unbalanced braces inside interpolation no longer confuse body parsing.

**Why:** README: `"pathological code with unbalanced braces inside ${...} may confuse the body parser."`

**Files:**
- Modify: `src/dart_parser.zig` (string-literal scanner around the interpolation tracker).
- Add: `testdata/review/dart_interp/before.dart`, `after.dart`, `expected.ndjson` with adversarial fixture (e.g., `'${ {} }'` and `'${"a${b}c"}'`).

**Acceptance criteria:**
- `'${ {} }'` parses without confusing body brace depth.
- Nested string interp `'${"x${y}z"}'` parses correctly.
- Existing Dart fixtures unaffected.

**Sizing:** M  
**Risk:** medium — the brace-counter touches the hottest part of the Dart parser.

---

## Phase 9 — JS regex/division token-stream disambiguation

**Goal:** Replace the heuristic last-token check with a proper lexer-state-machine context tracker so `/` is unambiguously regex or division.

**Why:** README: `"regex / division disambiguation is heuristic (last-token context). Pathological / placement may misclassify."`

**Files:**
- Modify: `src/js_parser.zig` (and `src/lex.zig` if shared lexer state needs the new context flag).
- Add: `testdata/parse/js_regex_div/` with the cases the heuristic misclassifies today.

**Acceptance criteria:**
- A regression suite of ≥10 ECMA-spec edge cases (e.g., `(a)/b/g` is division, `[/regex/]` is regex, `if (x) /re/.test(y)` is regex) all parse correctly.
- No Δ in existing fixtures.

**Sizing:** M  
**Risk:** medium — the JS lexer is shared with TS/TSX; changes ripple.

---

## Phase 10 — TSX JSX vs generic disambiguation

**Goal:** Make `.tsx` parsing recognize JSX tags and not treat `<Capital ...>` as a generic delimiter.

**Why:** README: `"deeply nested or self-closing custom tags may need manual workaround."`

**Files:**
- Modify: `src/ts_parser.zig` (the `<` → `skipBalanced('<', '>')` sites at lines 502, 719, 786, 900 per audit grep).
- Add: `testdata/parse/tsx_jsx/` covering `<Foo>`, `<Foo />`, `<Foo<T>>`, fragment `<>...</>`, and the JSX-vs-cast disambiguation `<Foo>(x)`.

**Acceptance criteria:**
- React-style component fixtures (e.g., `function App() { return <Foo a={1} />; }`) emit one `js_function` with the JSX absorbed into content range — no stray "unbalanced `<`" errors.
- Generic-only `.ts` fixtures unaffected.
- Mixed: a `.tsx` file with both `<T,>(x: T) => ...` (typed arrow) and `<Foo />` (component) parses both.

**Sizing:** M (could grow)  
**Risk:** high — JSX/generic ambiguity is genuinely undecidable in some cases. Document residual cases in the per-phase plan and ship best-effort.

---

## Phase 11 — MOVED-in-cascading-insert recovery

**Goal:** When `suppressCascade` would drop MOVEDs because their parent is MODIFIED-due-to-insert, retain the MOVED records that represent semantic reorders rather than mechanical shifts.

**Why:** README: `"an insert-then-everything-shifts cascade is suppressed because the parent is MODIFIED."` Real refactors (e.g., adding one method, then re-ordering siblings) lose the reorder signal.

**Files:**
- Modify: `src/differ.zig` `suppressCascade` (lines ~187–276 per audit grep).
- Add: `testdata/review/moved_under_modified/before.ts`, `after.ts`, `expected.ndjson`.

**Acceptance criteria:**
- Insert + sibling-reorder produces ADDED + N×MOVED, not just ADDED.
- Pure insert with no reorder still produces only ADDED (no false MOVEDs).
- Existing `key reorder reports MOVED` test in `differ.zig` stays green.

**Sizing:** M  
**Risk:** medium — `suppressCascade` is the densest logic in `differ.zig`; needs careful invariants.

---

## Cross-cutting

These items are not phases but show up in every plan:

- **Versioning policy:** any field added to `schemas/review-v1.json` must be additive (optional). A breaking change rev’s the version string in the schema header (`review-v1` → `review-v2`) and is opt-in via `--review --schema-version`.
- **Performance budget:** every phase must run `zig build bench` and prove ≤2% added overhead vs. `main`. The current review-mode total budget is `<15%` per README.
- **Snapshot stability:** new fixtures live under `testdata/review/<scenario>/`. Tests must be deterministic — no timestamps, no ordering by hash-map iteration.
- **Docs:** every phase that closes a bullet in `README.md > Limitations / known gaps` must also delete that bullet in the same PR.

---

## Self-review

- **Spec coverage:** every bullet in `README.md > Limitations / known gaps` (8 items) and `README.md > Out of scope (deferred)` (5 items) maps to a phase or is deliberately marked out of scope (LLM summaries, language bindings, HTTP server — not gaps, those are anti-features per the README).
- **Placeholders:** none. Every phase carries goal, files, acceptance criteria, sizing, and risk.
- **Type/name consistency:** kind names (`rust_fn`, `go_var`, `ts_interface`, etc.) match `src/ast.zig`; flag names (`--review`, `--group-by symbol`) match `src/main.zig`.

---

## Next step (handoff)

This roadmap is intentionally **not** a step-by-step TDD plan. Pick a phase (Phase 1 is recommended), then run:

```
/superpowers writing-plans

Spec: Phase 1 from docs/superpowers/plans/2026-05-03-roadmap-known-limitations-and-features.md
```

That will produce `docs/superpowers/plans/YYYY-MM-DD-<phase-slug>.md` with bite-sized TDD tasks, exact code, and commit boundaries. Execute via `superpowers:subagent-driven-development` or `superpowers:executing-plans`.
