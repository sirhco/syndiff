# Changelog

All notable changes to SynDiff. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); SynDiff has not yet hit 1.0 so versioning is by milestone rather than SemVer.

## [Unreleased]

### Added
- **Java parser** (`src/java_parser.zig`, ~1288 LOC): top-level package + import + class/interface/enum/record/`@interface`, recursive type-body decomposition into method/constructor/field/nested-type nodes. Modifier and annotation prefixes absorbed into content range. Generics skip-balanced (`<T>`); no JSX-style ambiguity. Multi-name fields split per-name (mirrors Go phase 5). 12 new `java_*` kinds appended after `file_root` to preserve enum-int values for existing fixtures. Java parse throughput n=10000 = 261 MB/s.
- **C#/.NET parser** (`src/csharp_parser.zig`, ~1794 LOC): file-scope using + namespace (block + file-scoped) + class/interface/enum/struct/record/delegate. Properties (auto + arrow-bodied + indexers), fields (multi-name), constants, events, constructors, finalizers, operator + conversion overloads. Interpolated strings (`$"{x}"`), verbatim strings (`@"..."`), raw string literals (`"""..."""` C# 11+), nullable reference types, `where` clauses, partial classes. 13 new `cs_*` kinds appended after `java_stmt`. C# parse throughput n=10000 = 246 MB/s.
- **`--complexity cyclomatic|stmt_count` flag** (workstream D2): selects algorithm for `complexity_delta`. Default cyclomatic (decision-point + 1, fn-level). `stmt_count` is the legacy pre-Phase-6 proxy (direct stmt children of the enclosing fn). Climbs to enclosing fn before counting so cascade-collapsed stmt rows still produce a meaningful proxy. Schema field `method` reflects the choice. Invalid values rejected with a clear error.
- **`is_alias` flag on `ast.Node`** (workstream D1): marks nodes that intentionally share `identity_hash` with an earlier node (e.g. YAML `*alias` → `&anchor`). `differ.buildMap` skips alias nodes when counting collisions so `hash_collisions` only flags genuine 64-bit clashes. Default `false` via field-level default — no addNode call-site changes elsewhere.
- **Sensitivity patterns for Java/C#** (workstream D follow-up): added 22 Java patterns (`MessageDigest`, `Cipher`, `KeyStore`, `SecureRandom`, `KeyPairGenerator`, `SecretKeySpec`, `PreparedStatement`, `Statement.execute`, `EntityManager`, `ProcessBuilder`, `Runtime.exec`, `HttpURLConnection`, `URLConnection`, `RestTemplate`, `OkHttpClient`, `FileWriter`, `FileOutputStream`, `Files.write`, `Files.delete`, `System.getenv`) and 22 C#/.NET patterns (`CryptoServiceProvider`, `RSACryptoServiceProvider`, `AesManaged`, `MD5.Create`, `SHA256.Create`, `SecureString`, `ClaimsPrincipal`, `IdentityUser`, `SqlCommand`, `SqlConnection`, `ExecuteNonQuery`, `ExecuteReader`, `DbContext`, `Process.Start`, `ProcessStartInfo`, `HttpClient`, `WebClient`, `WebRequest`, `File.WriteAll`, `FileStream`, `StreamWriter`, `Environment.GetEnvironmentVariable`, `ConfigurationManager`).
- **README polish**: source-layout block now includes all 24 `src/` files (was missing 10). Performance section refreshed with all 10 parser throughputs + review/json ratios at n=100/1000/10000. CHANGELOG.md (this file).

### Changed
- **Phase 1 status**: roadmap row 1 marked ✅. `extractTsInterface`, `extractTsType`, `extractTsEnum` already wired in `src/signature.zig` with fixtures `ts_interface_change`, `ts_type_change`, `ts_enum_change`. (`ts_namespace` and `abstract class` deliberately deferred — no useful signature shape for namespace; abstract class is absorbed as a `js_class` modifier.)

### Fixed
- Pre-existing `.zig` source leak in `parseLang` (surfaced by phase 6's complexity/zig snapshot test).

### Deferred (deliberate scope cuts)
- **`ts_namespace` and `abstract class` signature extraction**: namespace has no useful signature shape (it's a container); abstract class is absorbed as a `js_class` modifier rather than a distinct kind. README documents this.
- **C# attribute argument parsing** (`[Foo(arg)]`): absorbed into content range, not surfaced as sub-nodes.
- **C# LINQ query syntax**: body-internal expression; not decomposed.
- **C# expression trees** (`Expression<Func<T,U>>`): opaque.
- **C# `unsafe` / `fixed` / `stackalloc` blocks**: body-internal.
- **C# cross-file `partial` class coalescing**: each partial emits its own `cs_class` node.
- **C# top-level statements** (C# 9+): emit `cs_stmt` nodes; no synthetic `Main` wrapping.
- **Java module system** (`module-info.java`): parses but treated as opaque package-info-style.
- **Java anonymous class members** (`new Foo() { ... }`): body-internal.
- **Java lambdas, method references, switch expressions**: body-internal; absorbed.
- **Java enum constant override-method bodies**: absorbed into the constant's content range.
- **Java generic method type-parameter lists** (`public <T> T foo()`): skipped, not extracted as Param entries.
- **Reflection-string sensitivity patterns** for Java (`Class.forName`, `MethodHandles.lookup`) and C# (`Type.GetType`, `Activator.CreateInstance`): not added; relies on language-neutral pattern scan.
- **`--complexity=stmt_count` legacy proxy**: shipped as opt-in flag (D2). Default remains cyclomatic.

---

## Phase 11 — MOVED-cascade recovery (`3c72a65`)

### Changed
- `differ.suppressCascade` now distinguishes mechanical offset shifts (every sibling moved by the same byte delta) from semantic reorders (siblings moved by different deltas). Mechanical shifts are suppressed; semantic reorders retain ALL MOVED records under the affected parent. O(n) in the number of MOVED changes; one pass before the existing filter loop.
- README updates: drops the "MOVED-suppression lost in cascading-insert" limitation bullet.

### Added
- `testdata/review/moved_under_modified/`: insert + sibling-reorder fixture proves ADDED + N×MOVED is preserved.

---

## Phase 10 — TSX JSX vs generic disambiguation (`4b18df7`)

> Note: this commit's subject reads "feat(js,ts): goal-state machine for regex vs division" due to a commit-message mistake (it carries phase 9's subject). The diff is the phase 10 TSX work. Cosmetic; merged via PR #5.

### Added
- `Parser.is_tsx: bool` flag (set from path) on `src/ts_parser.zig`. Pure, allocation-free, bounded `classifyAngle` probe returns `.generic | .jsx_element | .jsx_fragment | .ambiguous_prefer_generic`. `skipAngleOrJsx` dispatcher replaces four header-walk `skipBalanced('<', '>')` call sites; an additional `<` arm in `skipStatement` handles JSX inside function bodies. Recursive `skipJsxElement` and `skipJsxFragment` scanners.
- `tests/tsx_jsx_parse.zig` (9 disambiguation cases) + `testdata/parse/tsx_jsx/` snippet fixtures + `testdata/review/tsx_component_change/` end-to-end snapshot.
- README documents supported TSX forms + `<T,>(x: T) => x` workaround for the residual undecidable case.

### Behavior
- `.tsx`: JSX recognized — `<Foo>`, `<Foo />`, `<Foo<T>>`, `<>...</>`, `<Foo>(x)`.
- `.ts`: unchanged.
- `.js`: unaffected (different parser).

---

## Phase 9 — JS regex/division disambiguation (`04f1d41`)

### Changed
- `src/js_parser.zig` and `src/ts_parser.zig` (parallel-copy parsers) replaced their `last_ctx: TokenContext` heuristic with a goal-state machine: `ParseGoal {regex, div}` updated as side-effect of each consumed token via `identGoalAfter` and `punctGoalAfter`. `BraceKind {block, object_literal}` disambiguates `}` per ECMA-262 Annex B.3.2 — block-statement `}` yields regex goal; object-literal `}` yields div goal.
- `lex.zig` is stateless and unchanged.

### Added
- `tests/js_regex_div.zig` (13 + 1 smoke unit tests). Fixture cases under `testdata/parse/js_regex_div/`: division after paren, regex in array, regex after control-stmt paren, regex after comment/return/throw, regex after block, division after object literal, regex/div after pre/post-fix inc, regex after fn decl, regex after arrow.

---

## Phase 8 — Dart `${...}` string-interpolation recursion (`27bd0e2`)

### Fixed
- `src/dart_parser.zig` `skipString` for non-raw, non-triple single/double-quoted strings now intercepts `${` and delegates to `skipBalanced('{', '}')` — recursion `skipString → skipInterpExpr → skipBalanced → skipString` correctly handles arbitrary nesting depth. Pathological inputs `'${ {} }'` and `'${"a${b}c"}'` no longer confuse the body brace counter. Triple-quoted strings also intercept `${` for the same reason.
- Raw strings (`r'...'`, `r"..."`) remain non-interpolated.

### Added
- `testdata/review/dart_interp/` adversarial fixture pair.

---

## Phase 7c — YAML folded and literal block scalars (`f907b70`)

### Added
- `src/yaml_parser.zig` `parseBlockScalar` consumes `>` (folded) and `|` (literal) bodies delimited by indent. `content_range` covers the literal byte span (indicator + body) so round-trip is verbatim; `identity_range` covers the body without the indicator line.
- Chomping suffixes (`>-`, `|+`, `>2`, `|+2`) explicitly out of scope — emit `error.UnsupportedBlockScalarChomping` on first sight.
- `testdata/review/yaml_folded/` fixture pair.

---

## Phase 7b — YAML anchors and aliases (`33d58d3`)

### Added
- `src/yaml_anchor_table.zig`: `StringHashMap<name → AnchorEntry>`. Parser registers `&name` on anchor declaration; `parseAlias` emits an alias node with `identity_hash` copied from the anchor target so first-write-wins coalesces alias occurrences with the anchor — modifying the anchor body produces a single MODIFIED record instead of one per occurrence.
- Tag-skip ignores `!str` / `!!int` tokens in front of a value (parser no longer crashes; tag is not stored).

### Design notes
- Alias `subtree_hash` is derived from the anchor name (stable) rather than copied from the anchor body, so parents that consume the alias don't cascade MODIFIED records every time the anchor body changes byte-for-byte.

---

## Phase 7a — YAML flow style (`e7852b5`)

### Added
- `src/yaml_parser.zig` `parseFlowMapping` / `parseFlowSequence` dispatched from `parseValue` and `parsePair` when `{` or `[` is seen. Reuses existing `yaml_mapping` / `yaml_sequence` / `yaml_pair` / `yaml_scalar` kinds so `{a: 1, b: 2}` hashes identically to its block-style equivalent — cross-style identity matching falls out for free.
- `testdata/review/yaml_flow/` fixture pair.

---

## Phase 6 — Real cyclomatic complexity (`5c447b3`)

### Added
- `src/complexity.zig`: per-`Kind` decision-point counter dispatch. Per-language scanners walk `tree.contentSlice` via existing `lex` helpers. `enclosingFn` climbs to the enclosing fn so cascade-collapsed stmt rows still produce fn-level complexity.
- `schemas/review-v1.json`: optional `method` enum on `complexity_delta` (`"cyclomatic"` | `"stmt_count"`). Additive — stays `review-v1`.
- 5 new fixtures under `testdata/review/complexity/{go,rust,zig,dart,js}/`.

### Changed
- `annotateComplexity` in `src/review.zig` calls `complexity.count` instead of `countStmtChildren`. Existing fixtures regenerated to include `"method":"cyclomatic"`.

### Fixed
- Pre-existing `.zig` source leak in `parseLang` discovered via the new complexity/zig snapshot.

---

## Phase 5 — Go multi-name `var x, y = ...` per-name nodes (`38c33d6`)

### Changed
- `src/go_parser.zig` `parseVarConst` now collects all comma-separated names then emits one `go_var` (or `go_const`) node per name. `content_range` spans the whole declaration text; only `identity_range` and `identity_hash` differ per name. Cross-file identity matching now tracks every name, not just the first.
- `testdata/review/go_multivar/` fixture pair.

### Design notes
- `rename.zig` is unchanged. Single-name rename on a multi-name var (`y` → `yy`) appears as `deleted`+`added`, not `renamed` — correct given the text-hash model and acceptable at this scope.

---

## Phase 4 — Rust `mod {}` body recursion (`481f4cc`)

### Changed
- `src/rust_parser.zig` `parseMod` previously called `skipBalanced('{','}')` and treated the body as opaque. Now uses `scanContainer` + `parent_idx` backpatch mirroring `parseImpl`, so items nested in `mod` blocks emit per-item records (`rust_fn`, `rust_struct`, etc.) with parent-composed identity hashes.

### Identity-hash shift
- Items previously at file scope that are manually moved into a `mod` block now appear as DELETED + ADDED rather than MOVED. Documented in README under known limitations.

---

## Phase 3 — Hash-collision detection (`11a60a8`)

### Added
- `src/differ.zig` `buildMap` threads a collision counter through to `DiffSet`. `src/review.zig` accumulates per-pair, emits `"hash_collisions": N` in the summary footer.
- `schemas/review-v1.json`: optional `hash_collisions` (integer ≥ 0) added to summary properties. Additive — stays `review-v1`.
- `tests/hash_collision.zig`: synthetic two-node collision unit tests.

### Behavior
- Silent first-write-wins behavior preserved; the counter makes the anomaly observable. Phase 7b later added `is_alias`-aware skipping so legitimate alias identity sharing doesn't inflate the counter.

---

## Phase 2 — Real JSON Schema validation in CI (`93000a7`)

### Added
- `tests/schema_validation.zig`: draft-07 validator runs against every `expected.ndjson` fixture line-by-line.
- Fixtures backfilled for every record kind (`testdata/review/{deleted_only,moved_only,test_not_updated,file_lifecycle}/`).
- Negative mutation test proves the validator is not a no-op.

### Fixed
- `build.zig`: pin schema-test cwd to project root.

---

## Earlier work

This file was started after the Phase 2–11 + Java + C# + workstream-D follow-ups landed. Earlier history (initial parsers, file-pair vs git modes, format dispatch, sensitivity heuristic, signature extraction for non-TS languages, etc.) lives in `git log` and the README.

[Unreleased]: https://github.com/sirhco/syndiff/commits/main
