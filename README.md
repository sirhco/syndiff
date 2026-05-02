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

| Ext             | Parser                    | Identity                                                                      |
|-----------------|---------------------------|-------------------------------------------------------------------------------|
| `.json`         | hand-rolled               | key path; arrays use index                                                    |
| `.yaml` / `.yml`| block-style subset         | key path; arrays use index                                                    |
| `.zig`          | `std.zig.Ast`             | top-level decl name (fn / struct / decl / test); anon decls disambiguated by position |
| `.rs`           | skim lexer + brace-counter | top-level item name; methods inside `impl` composed under impl signature      |
| `.go`           | skim lexer + brace-counter | top-level decl name; grouped `import/var/const/type` blocks split per-name    |

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

## Output formats

`--format` (alias `-F`) selects one of:

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
suppression and sorting.

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
├── json_parser.zig    recursive-descent JSON
├── yaml_parser.zig    block-style YAML subset
├── rust_parser.zig    skim lexer + impl-method recursion
├── go_parser.zig      skim lexer + grouped-decl splitting
├── zig_parser.zig     std.zig.Ast wrapper
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
- **Rust**: function bodies, trait bodies, mod bodies remain opaque (only impl
  bodies recurse). No statement-level tracking inside fn bodies — line-level
  diff fills that gap visually.
- **Go**: function bodies opaque. Multi-name `var x, y = 1, 2` emits one node
  with the first name as identity.
- **Hash collisions**: 64-bit identity hash; first-write-wins on collision.
  Astronomically rare with parent-composed identity.
- **MOVED detection**: byte-offset based. A pure reorder within an unchanged
  parent is detected; an insert-then-everything-shifts cascade is suppressed
  because the parent is `MODIFIED`.
