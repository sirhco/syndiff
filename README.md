# SynDiff

Semantic diff for structured data and source code. Reports changes by
**identity** rather than line number — so a key reorder is `MOVED`, a fn body
edit is `MODIFIED` on the function (not a smear of line changes), and a renamed
fn is `ADDED + DELETED` on the symbol level.

Written in Zig 0.16 with **standard library only**. Shells out to `git` for
ref-aware mode. Single binary, no runtime deps beyond `git` (optional).

## Install

```sh
git clone <this-repo>
cd syndiff
zig build -Doptimize=ReleaseFast
# binary at zig-out/bin/syndiff
```

Requires Zig **0.16.0** or newer.

## Quick examples

```sh
# Uncommitted changes, semantic diff against HEAD
syndiff

# Compare two commits
syndiff HEAD~3 HEAD

# Restrict to paths (forwarded to `git diff -- ...`)
syndiff main feature/x -- src/parser.rs

# Two arbitrary files
syndiff a.json b.json

# Pipe machine-readable JSON to jq
syndiff --format=json HEAD~1 | jq 'select(.kind=="modified")'

# Only show added items, no color
syndiff --color=never --only=added

# Enriched NDJSON for LLM-based review tools
syndiff --review HEAD~1 HEAD

# Same, but collapse statement-level edits under their enclosing fn
syndiff --review --group-by symbol HEAD~1 HEAD
```

## Workflow modes

### git-aware (primary)

Mirrors `git diff` argument shape:

| Invocation                    | Diffs                                  |
|-------------------------------|----------------------------------------|
| `syndiff`                     | `HEAD` → working tree                  |
| `syndiff <ref>`               | `<ref>` → working tree                 |
| `syndiff <ref1> <ref2>`       | `<ref1>` → `<ref2>`                    |
| `syndiff [refs] -- <path>...` | restrict files; same `--` as git        |

`<ref>` is whatever `git rev-parse` accepts: `HEAD`, `HEAD~3`, branch name,
tag, abbreviated SHA, `origin/main`. The runner calls `git diff --name-only`
to enumerate changed files, then `git show <ref>:<path>` to read each side.

Files with unsupported extensions are silently skipped and counted in the
trailing `(N unsupported files skipped)` line.

### File-pair

```sh
syndiff a.json b.json          # auto-detected when both args are files on disk
syndiff --files a.zig b.zig    # force file-pair mode
```

Used for ad-hoc comparisons outside a repo. Both files must have the same
extension; mismatched formats error out.

## Format support

Dispatch is by extension. Identity rules per format:

| Ext                       | Parser                    | Identity                                                                      |
|---------------------------|---------------------------|-------------------------------------------------------------------------------|
| `.json`                   | hand-rolled               | key path; arrays use index                                                    |
| `.yaml` / `.yml`          | block-style subset         | key path; arrays use index                                                    |
| `.zig`                    | `std.zig.Ast`             | top-level decl name (fn / struct / decl / test); anon decls disambiguated by position |
| `.rs`                     | skim lexer + brace-counter | top-level item name; methods inside `impl` composed under impl signature      |
| `.go`                     | skim lexer + brace-counter | top-level decl name; grouped `import/var/const/type` blocks split per-name    |
| `.dart`                   | skim lexer + brace-counter | top-level decl name; class members composed under class identity              |
| `.js` / `.mjs` / `.cjs`   | skim lexer + brace-counter | top-level decl name; class methods composed under class identity              |
| `.ts` / `.tsx` / `.mts` / `.cts` | skim lexer + brace-counter | TS keyword decls (interface / type / enum / namespace) plus all JS shapes |

Behavior for both YAML and JSON: parents whose only change is reordering
children fall back to the array/mapping subtree-hash comparison, so reordered
keys show as `MOVED` on each member, with the parent shown only when its hash
genuinely differs.

### YAML notes

Block-style subset only. Supported: nested mappings, block sequences, plain
scalars, single/double-quoted strings, comments, blank lines. **Not**
supported: flow style (`{...}`/`[...]`), anchors / aliases / tags, multi-doc
(`---`), folded / literal block scalars. Tab indentation rejected per spec.

### Rust notes

Top-level items recognized: `fn`, `struct`, `enum`, `union`, `trait`, `impl`,
`mod`, `use`, `const`, `static`, `type`, `extern`, `macro_rules!`, and macro
invocations. Leading attributes (`#[...]`, `#![...]`) and visibility prefixes
(`pub`, `pub(crate)`, etc.) are absorbed into the decl's content range, so an
attribute change shows as `MODIFIED` on the decl.

`impl` blocks recurse one level: each inner `fn` becomes a child node with
identity composed under the impl signature. `impl Foo { fn x }` and
`impl Bar { fn x }` produce distinct identities — diffs attribute correctly
across receiver types.

### Go notes

Top-level decls: `package`, `import`, `func`, methods (`func (recv) Name`),
`type`, `var`, `const`. Grouped declarations split per-name:

```go
import (
    "fmt"      // → go_import "fmt"
    "io"       // → go_import "io"
)
const (
    A = 1      // → go_const A
    B = 2      // → go_const B
)
```

Aliased imports use the path as identity:
- `alias "fmt"` → identity = `fmt`
- `_ "embed"` → identity = `embed`
- `. "math"` → identity = `math`

### Dart notes

Top-level decls: `import` / `export` / `library` / `part`, `typedef`,
`class` (with `abstract` modifier), `mixin`, `enum`, `extension`, plus
top-level functions and `var` / `final` / `const` bindings. Class bodies
recurse one level: methods and fields become children of the class node.

Strings: single-quoted, double-quoted, triple-quoted (`'''...'''`,
`"""..."""`), and raw (`r'...'`, `r"..."`). String interpolation `${...}`
is treated opaquely — the parser tracks escapes and respects matching
braces inside string literals, but does not recurse into the interpolation
expression. Pathological code with unbalanced braces inside `${...}` may
confuse the body parser.

### JavaScript notes

Top-level decls: `import` / `export`, `function` / `async function`,
`class`, `const` / `let` / `var`. Class bodies recurse one level: methods
become `js_method` nodes. Default exports unwrap to the inner named decl.

Template literals (`` `...${expr}...` ``) are handled as a small state
machine. Regex / division ambiguity is resolved heuristically by tracking
the last significant token: after expression-context (`(`, `=`, `,`,
`return`, `typeof`, ...), `/` starts a regex; after operand-context (`)`,
`]`, identifier, ...), `/` is division. Pathological code may misclassify
a `/`.

### TypeScript notes

Superset of JavaScript. Adds: `interface`, `type`, `enum`, `namespace` /
`module`, `declare`, and `abstract class`. Type annotations on params,
locals, and return types are absorbed into decl content ranges. Generic
parameters use the existing `<...>` balanced delimiter skip.

`.tsx` JSX limitation: `<Capital ...>` tags collide with generic syntax.
The header walker treats `<` as a balanced delimiter, which is correct for
generics but may misparse JSX in some forms. Plain `.ts` is unaffected.

### Function-body recursion

For Rust, Go, Zig, Dart, JavaScript, and TypeScript, function and method
bodies break into per-statement child nodes (`*_stmt` kinds). Statement
identity is index-based under the parent fn (`parent_id + stmt_index`),
matching the JSON-array convention. A single-statement body change
reports as `MODIFIED` on that stmt only — the enclosing fn is suppressed
by the cascade pass.

The index-based identity means inserting a stmt at the top of a body
shifts all following stmt identities. Cascade suppression handles this:
when many sibling stmts churn under a single MODIFIED parent fn, the
parent is reported alone.

## Output formats

`--format` (alias `-F`) selects one of `text`, `json`, `yaml`, `review-json`.
The first three are documented here. `review-json` (and its shortcut
`--review`) is a separate, much richer NDJSON stream covered in detail
under [Review mode](#review-mode---review).

### `text` (default)

```
MODIFIED a.rs:8:5 -> b.rs:8:5
    pub fn distance(p: &Point) -> f64 {
  -     let dx = p.x;
  +     let dx = p.x as f64;
  -     ((dx * dx + dy * dy) as f64).sqrt()
  +     (dx * dx + dy * dy + dz * dz).sqrt()
    }
ADDED   b.rs:13:5
  + pub fn origin() -> Self { Self::new(0, 0) }
```

Multi-line MODIFIED bodies use a unified-diff line view (LCS-based) so only
the changed lines are flagged. Single-line changes degrade to
`- old / + new`. The line-level pass is bounded; pathological inputs
(>4000 lines combined) fall back to whole-block view.

### `json` (NDJSON)

One event per line:

```json
{"kind":"modified","a":{"path":"a.rs","line":8,"col":5,"text":"..."},"b":{...}}
{"kind":"added","b":{"path":"b.rs","line":13,"col":5,"text":"..."}}
{"kind":"file_new","path":"build.zig","ref_a":"HEAD~3","ref_b":"HEAD"}
```

Strings JSON-escape control characters and embedded quotes. Pipe to `jq` for
filtering / aggregation.

### `yaml`

Top-level YAML sequence, double-quoted strings:

```yaml
- kind: modified
  a:
    path: "a.rs"
    line: 8
    col: 5
    text: "..."
  b:
    path: "b.rs"
    line: 8
    col: 5
    text: "..."
```

## Review mode (`--review`)

`--review` (alias `--format review-json`) emits an enriched, **versioned
NDJSON stream** (`review-v1`) designed for downstream LLM-based code-review
tools. Existing `--format json` and `--format yaml` outputs remain
byte-identical — review mode is purely additive.

Each line is a complete JSON object. The stream **always** begins with a
`schema` header and **always** ends with a `summary` footer, even across
multi-file diffs. Between them: one record per change, in source order.

### Invocation

```sh
# Git-aware: every changed file between two refs
syndiff --review HEAD~1 HEAD
syndiff --review main feature/auth-rewrite

# Restrict to paths
syndiff --review HEAD~3 -- src/auth/ src/middleware/

# File-pair: ad-hoc diff of two arbitrary files
syndiff --review --files a.go b.go
syndiff --review --files old.rs new.rs

# Equivalent long form
syndiff --format=review-json HEAD~1 HEAD

# Collapse statement-level edits under their enclosing fn record
syndiff --review --group-by symbol HEAD~1 HEAD

# Combine with path filtering and piping
syndiff --review HEAD~1 HEAD | jq 'select(.kind=="modified" and .is_exported)'
syndiff --review HEAD~1 HEAD | jq 'select(.sensitivity | length > 0)'
```

Exit code matches the rest of `syndiff`: `0` no changes, `1` changes found,
`2` invalid args / git failure / parse error. The NDJSON stream is
delivered on stdout regardless of exit code.

### CLI flags introduced

| Flag | Description |
|------|-------------|
| `--review` | Emit enriched NDJSON. Alias for `--format review-json`. |
| `--format review-json` | Same, long form. Composes with `--format=review-json`. |
| `--group-by symbol` | Review-mode only: collapse `*_stmt` changes into nested `sub_changes` arrays under their enclosing fn/method record. Default off. |

### Stream shape

```ndjson
{"kind":"schema","version":"review-v1","syndiff":"0.1.0"}
{"kind":"modified","change_id":"...","scope":"pkg.Foo.bar","kind_tag":"signature_change",...}
{"kind":"modified","change_id":"...","scope":"pkg.Foo.helper","kind_tag":"body_change",...}
{"kind":"renamed","change_id":"...","scope":"pkg.NewName",...,"a":{...},"b":{...}}
{"kind":"added","change_id":"...","scope":"pkg.Baz","kind_tag":"structural",...}
{"kind":"file_new","path":"src/feature.go","ref_a":"HEAD~1","ref_b":"HEAD"}
{"kind":"test_not_updated","path":"src/auth.go","reason":"no churn in src/auth_test.go"}
{"kind":"summary","files_changed":7,"counts":{...},"exported_changes":4,"sensitivity_totals":{...}}
```

### Record kinds

| `kind` | When emitted |
|--------|--------------|
| `schema` | First line. Carries `version` (`review-v1`) and `syndiff` build version. |
| `added` | New node in tree B with no identity match in A. |
| `deleted` | Node in tree A with no identity match in B. |
| `modified` | Same identity in A and B but subtree hash differs. |
| `moved` | Same identity + subtree hash but different byte offset (e.g., key reorder). |
| `renamed` | A `(deleted, added)` pair in the same parent scope with matching subtree hash OR matching signature shape (params + return + visibility). Single record carries both `a` and `b` location blocks. |
| `test_not_updated` | A non-test source path was changed but no co-changed test sibling exists per language convention. |
| `file_new` / `file_removed` | Whole-file events at the git level. |
| `summary` | Final line. Aggregates per-kind counts, exported-change count, sensitivity totals. |

### Per-record fields

Every change record (`added`/`deleted`/`modified`/`moved`/`renamed`) carries:

| Field | Type | Description |
|-------|------|-------------|
| `kind` | enum | One of the kinds above. |
| `change_id` | 16-char hex | Stable across runs (Wyhash of identity hashes + paths). Reviewers can dedupe and reference comments by id. |
| `scope` | string | Dotted parent-chain path (e.g. `pkg.Foo.bar`). Empty at file root. |
| `kind_tag` | enum | `signature_change` (identity bytes differ between A and B), `body_change` (only subtree hash differs), or `structural` (added/deleted/moved). |
| `is_exported` | bool | Per-language visibility heuristic on the changed node. False on stmt-level rows. |
| `lines_added`, `lines_removed` | u32 | Line churn within the change. For `added`/`deleted`: full line count of the side. For `modified`/`renamed`: LCS-based add/remove counts. |
| `sensitivity` | string array | Tags from the table below. Empty array when no patterns matched. |
| `complexity_delta` | object | `{stmt_a, stmt_b, delta, method}` — cyclomatic complexity (decision-point count + 1) of the enclosing function on each side. `method` is `"cyclomatic"` (default) or `"stmt_count"` (legacy proxy). |
| `signature_diff` | object | Only on `modified`/`renamed` of fn/method nodes when at least one of {params, return type, visibility} differs. |
| `callsites` | array | Only on records with `kind_tag = signature_change`. List of `{path, line}` pairs in the diff scope where the symbol is referenced. |
| `sub_changes` | array | Only with `--group-by symbol`. Nested change records (one level deep) for stmt-level edits whose immediate parent is the current record. |
| `a`, `b` | object | Location blocks: `{path, line, col, text}`. `a` omitted on `added`, `b` omitted on `deleted`. |

### `signature_diff` shape

```json
{
  "params_added":   [{"name":"ctx", "type":"Context"}],
  "params_removed": [],
  "params_changed": [{"name":"id", "from":"int", "to":"string"}],
  "return_changed": false,
  "visibility_changed": true
}
```

The block is **omitted** entirely when none of the five sub-fields carries
content — keeps fixture output stable on body-only modifications. Param
matching is by name; type-mismatch counts as `changed`, missing-in-B as
`removed`, missing-in-A as `added`.

Per-language extraction notes:
- **Go**: types after names (`name Type`); return between `)` and `{`. Visibility = capital initial letter.
- **Rust**: each param `name: Type`; return after `->`. Visibility = leading `pub`.
- **Zig**: same shape as Rust syntactically; no `->`.
- **Dart**: types **before** names (`Type name`); return type before fn name.
- **JS**: param names only, no types. `return_type` always `null`.
- TS-only kinds: `ts_interface` (members as params), `ts_type` (union variants as params), `ts_enum` (variants as params). `ts_namespace`/`ts_declare` remain skipped.

### Sensitivity tags

Heuristic byte-scan over the changed node's content. False positives are
expected and tolerated — the review agent decides relevance.

| Tag | Triggers (sample) |
|-----|-------------------|
| `crypto` | `sha`, `md5`, `hmac`, `aes`, `rsa`, `bcrypt`, `argon2`, `encrypt`, `decrypt` |
| `auth` | `password`, `token`, `jwt`, `session`, `oauth`, `login`, `permission` |
| `sql` | uppercase `SELECT `, `INSERT `, `UPDATE `, `DELETE `, `DROP ` |
| `shell` | `exec(`, `os/exec`, `subprocess`, `Runtime.getRuntime` |
| `network` | `http.`, `fetch(`, `axios` |
| `fs_io` | `ioutil.`, `WriteFile`, `removeAll` |
| `secrets` | `os.Getenv`, `process.env.`, `apiKey`, `AWS_` |

Patterns use word-boundary matching where ambiguous: `sha` matches `shaXXX`
calls but not `shadowed`. SQL is case-sensitive intentionally — lowercase
`select(...)` won't fire (it's almost always a method, not a query).

### Summary footer

```json
{
  "kind": "summary",
  "files_changed": 7,
  "counts": {"added": 3, "deleted": 1, "modified": 12, "moved": 2, "renamed": 1},
  "exported_changes": 4,
  "sensitivity_totals": {"crypto": 1, "auth": 3, "sql": 2, "shell": 0, "network": 0, "fs_io": 0, "secrets": 0}
}
```

`counts` reflects the post-rename pairing tally — a `renamed` row decrements
both `added` and `deleted` by one. `exported_changes` counts records with
`is_exported: true`. `sensitivity_totals` is a per-tag count across all
records (a record with two tags increments two counters).

### `--group-by symbol`

Off by default. When set, `*_stmt` changes whose immediate parent (the
enclosing fn/method) is **also** a change in the diff are nested under that
parent record as `sub_changes`. Stmt changes whose parent is not in the
changeset are still emitted at the top level.

```ndjson
{"kind":"modified","change_id":"...","scope":"Foo","kind_tag":"body_change",...,
 "sub_changes":[
   {"kind":"modified","change_id":"...","scope":"Foo","kind_tag":"body_change",...},
   {"kind":"modified","change_id":"...","scope":"Foo","kind_tag":"body_change",...}
 ]}
```

`sub_changes` is one level deep — nested records do not themselves carry a
`sub_changes` field. The top-level `summary.counts` still reflects the
total change count (parent + nested), not the rendered record count.

### `test_not_updated` heuristic

Per-language convention. After processing all files in a multi-file diff:

| Lang | Source path | Expected test |
|------|-------------|---------------|
| Go | `path/foo.go` | `path/foo_test.go` |
| JS / TS | `path/foo.ts` | `path/foo.test.ts` or `path/foo.spec.ts` |
| Dart | `lib/foo.dart` | `test/foo_test.dart` |
| Rust | (skipped — inline `#[cfg(test)] mod tests`) | — |

If a non-test source path is in the changeset but its expected test sibling
is not, an informational record is emitted before the summary:

```json
{"kind":"test_not_updated","path":"src/auth.go","reason":"no churn in src/auth_test.go"}
```

These records do not contribute to `summary.counts`.

### Schema

Full JSON Schema (draft-07) at [`schemas/review-v1.json`](schemas/review-v1.json).
The schema covers every record kind including all optional fields. The
version string in the header (`review-v1`) is bumped to `review-v2` on any
breaking change. Additive fields do not bump the version.

Every fixture under `testdata/review/<scenario>/expected.ndjson` is
validated line-by-line against `schemas/review-v1.json` by
`tests/schema_validation.zig`, using a vendored draft-07 subset validator
in `src/schema_validator.zig`. Schema/fixture drift fails CI with a
precise `path:line: <message> at <json_pointer>` report.

Supported schema keywords: `type`, `const`, `enum`, `required`,
`properties`, `items`, `minimum`, `pattern`, `oneOf`, `$ref` (root and
`#/$defs/<name>`). Pattern syntax is anchored (`^...$`) with literal
characters, character classes `[a-z0-9]`, and `{N}` quantifiers — adding
a new schema construct requires extending the validator first.

### Performance

Microbenchmarks (`zig build bench`) on synthetic Go corpora:

| n_fns | `--format=json` | `--review` | ratio |
|------:|----------------:|-----------:|------:|
|   100 |        22.0 µs |    26.7 µs | 1.21x |
|  1000 |       282.4 µs |   276.3 µs | 0.98x |
| 10000 |      3193.3 µs |  3165.0 µs | 0.99x |

Review mode adds <1% on realistic input sizes; small-input ratio variance
reflects timer noise. The plan's <15% overhead target is met with
significant margin.

### Integrating a downstream review tool

The boundary is the JSON contract — no Zig bindings, no in-process API.
A typical integration:

1. Run `syndiff --review <ref_a> <ref_b>`.
2. Parse stdout line-by-line. Skip empty lines.
3. Validate the first line is a `schema` record with the expected version.
4. Process each subsequent line as one of the record kinds above.
5. Use `change_id` as the dedupe / comment-anchor key.
6. Use `scope` to locate the change in the source tree.
7. Use `is_exported`, `sensitivity`, `signature_diff`, `callsites` to
   prioritize which changes the LLM reviewer surfaces.
8. The final `summary` line is the explicit terminator.

Exit code conveys overall change presence; the stream itself is the data.
The CLI prints nothing to stderr in review mode unless an error occurs.

### Out of scope (deferred)

- Cross-file symbol resolution beyond in-diff scope (callsites only span the changed file set)
- HTTP / webhook server mode — subprocess-only
- LLM-generated summaries inside syndiff itself — that is the downstream review tool's job
- Bindings for Go / Python / Node — the JSON contract is the boundary

## Color

`--color` accepts `auto` (default), `always`, `never`. `--no-color` is an
alias for `--color=never`. `auto` enables ANSI codes only when stdout is a
TTY. Color applies to text mode only — `json`/`yaml` always emit raw.

Palette:
- bold yellow `MODIFIED`, bold green `ADDED`, bold red `DELETED`, bold cyan `MOVED`
- cyan `path:line:col`
- red `-`, green `+`, yellow `~` markers
- syntax highlighting inside content: magenta keywords, green strings,
  yellow numbers, dim grey comments

## Filter

`--only KINDS` keeps only the listed change kinds. Comma-separated:

```sh
syndiff --only=added,modified
syndiff --only=deleted
```

Valid kinds: `added`, `deleted`, `modified`, `moved`. Applied after cascade
suppression and sorting. Note: `renamed` is a review-mode-only synthetic
kind produced by post-processing in `--review`; it is not accepted by
`--only` because the underlying differ never emits it directly.

## Exit codes

| Code | Meaning                                            |
|------|----------------------------------------------------|
| 0    | No changes (or `--help`/`--version`)               |
| 1    | Changes found                                      |
| 2    | Invalid arguments, git failure, or parse error     |

Mirrors `diff(1)` semantics; CI scripts can chain on exit status.

## Architecture

Per-file pipeline:

```
source bytes → format-specific parser → ast.Tree (DOD)
                                          ↓
              ast.Tree (HEAD) ─┐
                               ├─→ differ.diff → DiffSet
              ast.Tree (WT)  ──┘                     ↓
                                          suppressCascade
                                                     ↓
                                          sortByLocation
                                                     ↓
                                          filter (--only)
                                                     ↓
                                          render { text | json | yaml }
```

### Data-Oriented AST (`src/ast.zig`)

Nodes live in a `std.MultiArrayList(Node)` — each field gets its own
contiguous column. Hot scans (e.g. `slice().items(.identity_hash)`) walk a
packed `[]u64`, prefetcher-friendly. Per-file `std.heap.ArenaAllocator` owns
the node array; one `arena.deinit()` frees the whole tree.

Node fields:
- `hash: u64` — full subtree hash (for MODIFIED detection)
- `identity_hash: u64` — semantic identity (for cross-file matching)
- `kind: Kind` — language- and structure-specific tag
- `depth: u16`, `parent_idx: NodeIndex`
- `content_range: Range`, `identity_range: Range` — byte offsets into source

Children are pushed before parents (post-order). `parent_idx` backpatched
after parent emits.

### Hashing (`src/hash.zig`)

Both hashes use `std.hash.Wyhash`:

- `identityHash(parent_identity, kind, identity_bytes)` — composes parent
  context, so `user.name` and `org.name` get distinct identities
- `subtreeHash(kind, child_hashes, leaf_bytes)` — bottom-up; same shape +
  same children + same leaf bytes ⇒ same hash

### Differ (`src/differ.zig`)

`std.AutoHashMap(u64, NodeIndex)` per tree keyed on `identity_hash`. O(1)
cross-file lookup. `suppressCascade` drops noise:
- MODIFIED ancestors when a descendant is MODIFIED (deepest is the truth)
- MODIFIED that's purely structural (parent of an ADDED/DELETED child)
- MOVED children whose ancestor in B is structurally changed

### Git layer (`src/git.zig`)

Wraps the `git` CLI. Sentinel `WORKTREE = ""` ref means "read from disk
instead of `git show`". `listChangedFiles` calls `git diff --name-only`,
`readAtRef` calls `git show <ref>:<path>`.

## Build steps

| Step                              | What                                              |
|-----------------------------------|---------------------------------------------------|
| `zig build`                       | Build `syndiff` exe to `zig-out/bin/`             |
| `zig build run -- <args>`         | Build and run                                     |
| `zig build test`                  | Run all unit tests                                |
| `zig build test --fuzz`           | Run fuzz targets (parsers)                        |
| `zig build bench`                 | Run microbenchmarks (ReleaseFast by default)      |

`-Dbench-optimize=Debug` overrides bench compile mode.

## Performance

Best-of-5 throughput on M-series Mac (ReleaseFast):

```
json parse n=10000        128 KB    751 µs    170 MB/s
yaml parse n=10000        118 KB    770 µs    153 MB/s
go parse n=10000          418 KB    752 µs    555 MB/s
rust parse n=10000        408 KB    742 µs    549 MB/s
zig parse n=10000         458 KB   2136 µs    214 MB/s
json diff n=10000 (eq)    256 KB   2206 µs    116 MB/s
```

Skim-lexer parsers (Rust/Go) hit ~550 MB/s. Full-grammar parsers (JSON/YAML
recursive-descent, Zig via `std.zig.Ast`) range 150–215 MB/s.

## Source layout

```
src/
├── ast.zig            DOD Node + Tree, MultiArrayList layout
├── hash.zig           identity/subtree hashing
├── lex.zig            shared skim-lexer primitives
├── json_parser.zig    recursive-descent JSON
├── yaml_parser.zig    block-style YAML subset
├── rust_parser.zig    skim lexer + impl-method + fn-body recursion
├── go_parser.zig      skim lexer + grouped-decl + fn-body recursion
├── zig_parser.zig     std.zig.Ast wrapper + fn-body recursion
├── dart_parser.zig    skim lexer + class-member + fn-body recursion
├── js_parser.zig      skim lexer + class-method + fn-body recursion
├── ts_parser.zig      js_parser plus TS keyword decls
├── differ.zig         diff/filter/render
├── line_diff.zig      LCS-based unified diff for MODIFIED bodies
├── syntax.zig         per-language token tokenizer for highlighting
├── git.zig            git CLI wrapper
├── bench.zig          microbenchmark binary
├── main.zig           CLI entry: arg parsing, runners, dispatch
└── root.zig           library root (public re-exports)
```

## Limitations / known gaps

- **YAML**: subset only — no flow style, no anchors/aliases, no folded scalars.
- **Rust**: trait bodies remain opaque. Function bodies emit `rust_stmt`
  children. `mod foo { ... }` bodies are recursed: items inside emit as
  `rust_fn`, `rust_struct`, `rust_impl`, etc. with parent-composed identity
  hashes (`mod_identity = identityHash(parent, .rust_mod, "foo")`). Items can
  be nested arbitrarily deep (`mod outer { mod inner { fn f() {} } }`).
  `mod foo;` (external-file declaration) emits a single opaque `rust_mod`
  record with no children — the body lives in another file.
- **Rust `mod` identity shift (Phase 4):** Items previously at file scope
  that are manually moved into a `mod` block will appear as DELETED
  (file-scope identity) + ADDED (mod-scoped identity) rather than MOVED.
  This is semantically correct — the item's qualified path changed.
  No migration flag is provided; the identity change is intentional and
  documented here for operators upgrading across this phase boundary.
- **Dart**: string interpolation `${...}` is treated opaquely. The parser
  respects matching braces inside string literals but does not recurse into
  the interpolation expression — pathological code with unbalanced braces
  inside `${...}` may confuse the body parser.
- **JavaScript**: regex / division disambiguation is heuristic
  (last-token context). Pathological `/` placement may misclassify.
- **TypeScript / `.tsx`**: JSX tag handling collides with generic syntax
  (`<Foo>...</Foo>` vs `<T>(x: T)`). The header walker treats `<` as a
  balanced delimiter; deeply nested or self-closing custom tags may need
  manual workaround. Plain `.ts` is unaffected.
- **MOVED detection**: byte-offset based. A pure reorder within an unchanged
  parent is detected; an insert-then-everything-shifts cascade is suppressed
  because the parent is `MODIFIED`.
