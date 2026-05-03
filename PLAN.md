Enhancements to syndiff

 Syndiff Review-Mode Pipeline                                                                                                                                                                 
 Context                                                                                                                                                                                                 
 Syndiff today emits accurate semantic diffs (added/deleted/modified/moved) keyed by identity hash, but the NDJSON record set is too thin for an LLM-based code review tool. A
 reviewer agent needs scope, exported-API status, signature deltas, sensitivity hints, complexity proxies, rename detection, callsite impact, and test-coverage hints. All current
  consumers must figure these out from raw text fields.

 Goal: ship a --review mode that emits an enriched, versioned NDJSON stream consumable by a downstream review agent for PR description generation, breaking-change detection,
 security flagging, and code-smell hints. Integration shape is subprocess + JSON — no bindings.

 Scope: all three tiers (schema enrichment, signature/sensitivity, rename + symbol + test pairing).

 ---
 Recommended Approach

 Add a single new output mode --review (alias --format review-json) that runs the existing diff pipeline, then layers enrichments before NDJSON render. Existing --format
 json|yaml stay byte-identical (zero-regression for current consumers).

 Enrichment pipeline order (each pass is independent and skippable for tests):

 parse → diff → suppressCascade → sortByLocation
   → annotateScope         (Tier 1)
   → annotateExport        (Tier 1)
   → annotateLineChurn     (Tier 1)
   → annotateKindTag       (Tier 1: signature_change vs body_change)
   → renamePairing         (Tier 3)
   → annotateSignatureDelta(Tier 2)
   → annotateSensitivity   (Tier 2)
   → annotateComplexity    (Tier 3)
   → groupBySymbol         (Tier 3, optional via --group-by symbol)
   → annotateCallsites     (Tier 3, only when signature_change)
   → annotateTestPairing   (Tier 3, file-level pass)
   → renderReviewJson

 ---
 Schema (review-v1)

 Stream begins with a header, ends with a summary. Between them, one record per change.

 {"kind":"schema","version":"review-v1","syndiff":"<version>"}
 {"kind":"modified","change_id":"<stable-hash>","scope":"pkg/Foo.bar","kind_tag":"signature_change",
  "is_exported":true,"sensitivity":["auth","crypto"],
  "lines_added":3,"lines_removed":1,"complexity_delta":{"stmt_a":12,"stmt_b":14,"delta":2},
  "signature_diff":{"params_added":[{"name":"ctx","type":"Context"}],"params_removed":[],
                    "params_changed":[{"name":"id","from":"int","to":"string"}],
                    "return_changed":false,"visibility_changed":false},
  "callsites":[{"path":"x.go","line":42}],
  "a":{"path":"a.go","line":8,"col":1,"text":"..."},
  "b":{"path":"b.go","line":8,"col":1,"text":"..."}}
 {"kind":"renamed","change_id":"...","scope":"pkg/Foo","is_exported":true,
  "a":{"path":"a.go","line":3,"col":1,"text":"oldName"},
  "b":{"path":"b.go","line":3,"col":1,"text":"newName"},
  "signature_diff":{...}}
 {"kind":"test_not_updated","path":"src/auth.go","reason":"no churn in src/auth_test.go"}
 {"kind":"summary","files_changed":7,
  "counts":{"added":3,"deleted":1,"modified":12,"moved":2,"renamed":1},
  "exported_changes":4,"breaking_signature_changes":2,
  "sensitivity_totals":{"auth":3,"crypto":1,"sql":2}}

 Versioned — bump to review-v2 for any breaking schema change.

 ---
 Tier 1 — Schema Enrichment

 ┌─────────────────────┬─────────────────────────────────────────────────────────────────────────────────┬────────────────────────────────────────────────────────────────────┐
 │        Field        │                                     Source                                      │                               Notes                                │
 ├─────────────────────┼─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
 │ change_id           │ xxhash(identity_hash_a ‖ identity_hash_b ‖ path_a ‖ path_b)                     │ Stable across runs; review tool can dedupe and reference comments  │
 │                     │                                                                                 │ by id.                                                             │
 ├─────────────────────┼─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
 │ scope               │ Walk parent_idx chain in src/ast.zig:155 childrenOf (inverse), join names by .  │ Per-language separator.                                            │
 │                     │ or /                                                                            │                                                                    │
 ├─────────────────────┼─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
 │ kind_tag            │ signature_change if identity_range_hash_a != identity_range_hash_b; else        │ Needs new identity_range_hash column on Node (cheap — hash of      │
 │                     │ body_change                                                                     │ identity_range slice).                                             │
 ├─────────────────────┼─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
 │ is_exported         │ Per-language heuristic in parser; sidecar MultiArrayList column on Node,        │ Go: capitalized; Rust/Zig: pub; JS/TS: export; Dart: not           │
 │                     │ populated only for decl kinds                                                   │ _-prefixed.                                                        │
 ├─────────────────────┼─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
 │ lines_added/removed │ Already computed in src/line_diff.zig for MODIFIED render; expose count         │ Zero for added/deleted/moved (use full text length / line count    │
 │                     │                                                                                 │ instead).                                                          │
 ├─────────────────────┼─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────┤
 │ summary record      │ Aggregator across DiffSet                                                       │ Emitted last.                                                      │
 └─────────────────────┴─────────────────────────────────────────────────────────────────────────────────┴────────────────────────────────────────────────────────────────────┘

 Files to modify:
 - src/ast.zig — add identity_range_hash: u64 and is_exported: bool to Node (struct ~39B → ~48B; MultiArrayList keeps cache-friendly)
 - src/differ.zig — populate identity_range_hash during diff or parse phase
 - All src/*_parser.zig — set is_exported on decl nodes
 - New src/review.zig — orchestrator + renderer

 ---
 Tier 2 — Signature Deltas + Sensitivity

 Signature extraction

 New src/signature.zig exposing extractSignature(tree, idx) → ?Signature dispatched by Node.kind. Per-language sub-extractors:

 pub const Signature = struct {
     name: []const u8,
     params: []Param,        // {name, type_str, has_default}
     return_type: ?[]const u8,
     visibility: Visibility, // public/private/protected/package
     modifiers: Modifiers,   // async/static/const/etc bitfield
     hash: u64,              // for rename pairing in Tier 3
 };

 Implement for: go_fn, go_method, rust_fn, zig_fn_decl, dart_fn, dart_method, js_function, js_method, ts_* variants. Reuse the existing parser's tokenizer per language —
 signature parsing only runs on changed nodes (cheap).

 For records with kind_tag=signature_change, diff signatures and emit signature_diff block.

 Sensitivity tagger

 New src/sensitivity.zig. Single regex pass over contentSlice and identitySlice of each change. Tag taxonomy (fixed):

 ┌─────────┬─────────────────────────────────────────────────────────────────────────────────┐
 │   Tag   │                                    Triggers                                     │
 ├─────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ crypto  │ sha\d, md5, hmac, aes, rsa, bcrypt, argon2, sign, verify, decrypt, encrypt      │
 ├─────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ auth    │ password, token, jwt, session, oauth, login, authn, authz, permission, role     │
 ├─────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ sql     │ \bSELECT\b, \bINSERT\b, \bUPDATE\b, \bDELETE\b, \bDROP\b, raw query string lits │
 ├─────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ shell   │ exec, system, os/exec, subprocess, Runtime\.getRuntime, Process\.start          │
 ├─────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ network │ http\., fetch\(, Dial, Listen, request\(, axios                                 │
 ├─────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ fs_io   │ os\.Open, ioutil\., fs\., unlink, removeAll, WriteFile                          │
 ├─────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ secrets │ os\.Getenv, process\.env\., apiKey, AWS_, _TOKEN, hardcoded key= strings        │
 └─────────┴─────────────────────────────────────────────────────────────────────────────────┘

 Record emits "sensitivity":["auth","crypto"] (omitted if empty). Heuristic-only — false positives expected; review agent decides relevance.

 Files to add: src/signature.zig, src/sensitivity.zig. Modify src/review.zig to call them.

 ---
 Tier 3 — Rename, Symbols, Hunk Grouping, Test Pairing

 Rename pairing

 New src/rename.zig. Run after initial diff. For each (deleted, added) pair sharing the same parent scope:
 - If Signature.hash matches → renamed
 - If subtree Node.hash matches but identity differs → renamed (body intact, name changed)
 - Otherwise leave as separate add+delete

 Emit single kind:"renamed" record with both a and b populated. Decrement add/delete counts in summary.

 Symbol table + callsites

 New src/symbols.zig. Build only when at least one signature_change exists (skip cost otherwise). Single pass over both trees collecting identifier references. For each changed
 signature symbol, list call sites in the same diff scope as callsites:[{path,line}]. Bounded — only emits sites within files in the DiffSet, not whole repo.

 Hunk grouping (--group-by symbol)

 Optional flag. Aggregates statement-level child changes (*_stmt) under the enclosing fn/method record as nested sub_changes. LLM-friendly: one record per logical unit. Default
 off (preserves current granularity).

 Complexity delta

 Per-fn/method MODIFIED: count *_stmt children in tree A vs tree B (already a single childrenOf call). Emit complexity_delta:{stmt_a, stmt_b, delta}. Cheap proxy — not
 cyclomatic, but useful churn signal.

 Test pairing

 New src/test_pair.zig. After collecting all changed paths, apply per-language convention:
 - Go: foo.go ↔ foo_test.go
 - Rust: foo.rs ↔ inline #[cfg(test)] mod (skip — not a separate file)
 - JS/TS: foo.ts ↔ foo.test.ts / foo.spec.ts / __tests__/foo.ts
 - Dart: lib/foo.dart ↔ test/foo_test.dart

 For non-test source files with changes but no co-changed test file, emit kind:"test_not_updated" informational record.

 Files to add: src/rename.zig, src/symbols.zig, src/test_pair.zig. Modify src/review.zig and src/main.zig.

 ---
 Critical Files

 ┌──────────────────────────────────────┬───────────────────────────────────────────────────────────────────────────────────┐
 │                 File                 │                                      Change                                       │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ src/main.zig:195 parseArgs           │ Add --review flag, --format review-json, --group-by symbol                        │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ src/main.zig:360,412 runFiles/runGit │ Dispatch to review.render when flag set                                           │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ src/ast.zig:100 Node                 │ Add identity_range_hash: u64, is_exported: bool                                   │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ src/differ.zig:88 Change             │ Sidecar ChangeMeta array for tier 1+ enrichments (avoid bloating Change struct)   │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ src/differ.zig:335 renderJson        │ Unchanged. New renderer in review.zig                                             │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ src/line_diff.zig                    │ Expose (added, removed) counts as separate function (currently inlined in render) │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ New src/review.zig                   │ Orchestrator + NDJSON renderer                                                    │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ New src/signature.zig                │ Per-language signature extraction                                                 │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ New src/sensitivity.zig              │ Regex-based tagger                                                                │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ New src/rename.zig                   │ Add+delete pairing                                                                │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ New src/symbols.zig                  │ Minimal symbol table for callsite tracking                                        │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ New src/test_pair.zig                │ Test co-change heuristic                                                          │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ All src/*_parser.zig                 │ Set is_exported on decl nodes; expose signature ranges where cheap                │
 ├──────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
 │ src/root.zig                         │ Re-export new modules                                                             │
 └──────────────────────────────────────┴───────────────────────────────────────────────────────────────────────────────────┘

 ---
 Reuse

 - differ.diff / suppressCascade / sortByLocation / filter — pipeline foundation, untouched
 - ast.Tree.contentSlice / identitySlice / lineCol / childrenOf — scope path + range access
 - ast.Node.identity_hash / hash — rename pairing primary signal
 - line_diff.writeUnified LCS — reuse for lines_added/removed counts (factor out counter)
 - git.listChangedFiles / readAtRef — already drives multi-file mode

 ---
 Verification

 1. Unit tests (Zig test blocks):
   - src/signature.zig — fixture pairs per language asserting param add/remove/type-change detection
   - src/sensitivity.zig — positive + negative cases per tag (false-positive bound)
   - src/rename.zig — same body different name → renamed; same name different body → modified
   - src/test_pair.zig — Go/JS/TS/Dart conventions
 2. Snapshot tests under testdata/review/:
   - simple_signature_change/{a.go,b.go,expected.ndjson}
   - rename_only/{a.rs,b.rs,expected.ndjson}
   - security_touch/{a.go,b.go,expected.ndjson} (auth+crypto+sql tags)
   - body_only/{a.ts,b.ts,expected.ndjson} (body_change kind_tag)
   - test_not_updated/{src/foo.go,src/foo.go.b} (no foo_test.go change → record emitted)
   - Run syndiff --review --no-color a b and diff against expected.ndjson
 3. End-to-end with real PR: pick a PR from this repo's history, run syndiff --review HEAD~1 HEAD, verify summary counts match git diff --stat file count, eyeball signature_diff
 records.
 4. Performance regression: existing benchmarks/ suite — assert --review adds <15% over --format json on the kernel/TS-corpus benchmarks.
 5. Schema validation: write schemas/review-v1.json (JSON Schema) and validate snapshot outputs against it in CI.

 ---
 Out of Scope (Defer)

 - Cross-file symbol resolution (full project index) — bounded to in-diff scope only
 - Cyclomatic complexity (only stmt-count proxy in v1)
 - Webhook / HTTP server mode (still subprocess-only)
 - LLM-generated summaries inside syndiff itself — that's the downstream review tool's job
 - Bindings for Go/Python/Node — JSON contract is the boundary
