# Rule Engine Design Document

*A Japanese translation is kept for reference at [docs/RULE_ENGINE_DESIGN_jp.md](RULE_ENGINE_DESIGN_jp.md); this English version is canonical.*

This document summarizes the overall design of rawpaco's lint rule engine. It is written to be consistent with the development rules in CLAUDE.md and the purpose/approach described in README.md. Any major, unresolved policy questions are split out into "7. Open Questions / Proposals" rather than being decided unilaterally here. For a bird's-eye view of the overall system flow as Mermaid diagrams, see [docs/SYSTEM_FLOW.md](SYSTEM_FLOW.md).

This document is written on the assumption that Sonnet5 will handle the implementation. Each item's owner is noted at its end; when omitted, Sonnet5 is assumed (per the original request). Items that require complex algorithm design, ambiguous specification judgment calls, or major architectural decisions are explicitly marked "Owner: Opus5".

## 0. Assumptions and Constraints

rawpaco is a tool that performs **syntax analysis only**, via tree-sitter-pascal, and therefore cannot do the following:

- Type resolution (it cannot determine the type of a variable or expression; what an `identifier` refers to can only be inferred from its syntactic position)
- Scope resolution (name resolution across declaration and use sites; it cannot distinguish between identically-named identifiers in different scopes)
- Querying external registries or package managers (there is no way to check over the network whether a given unit or package actually exists, or whether it's the right version)
- Runtime information (the actual contents of values, proof of null-safety, etc.)

For this reason, the design below consistently distinguishes between what can be safely detected as a syntactic pattern and what is, in principle, undetectable without semantic/type information — and for the latter, alternative approaches (bundling static data, using the compiler itself as an oracle, etc.) are noted explicitly. Given CLAUDE.md rule 5 (prioritize avoiding false positives; when in doubt, let it go), anything that "seems detectable but isn't certain" is deliberately excluded from scope.

## 1. Rule Engine API Design

### 1.1 Overall Architecture

```
rawpaco.lpr (CLI entry point)
  └─ LintDriver.pas   … enumerates target files, parses, walks, aggregates diagnostics, outputs, decides exit code
       ├─ ASTWalker.pas   … generic driver that walks the TSNode tree via the tree-sitter cursor API
       ├─ RuleRegistry.pas … rule registration and the per-node-type dispatch table
       ├─ Diagnostics.pas  … the TDiagnostic record, output formatter
       └─ Rules/*.pas      … rule bodies (one unit per rule)
```

Currently, `src/rawpaco.lpr` is just a bootstrap self-check program that confirms tree-sitter-pascal works; the structure above does not exist yet. The plan is to split out `LintDriver`/`ASTWalker`/`RuleRegistry`/`Diagnostics` when the first rule is implemented. (Owner: Sonnet5)

### 1.2 TSBindings.pas needs to be extended

Currently, `src/TSBindings.pas` only declares the minimal functions needed for the bootstrap self-check (`ts_parser_new`, `ts_parser_set_language`, `ts_parser_parse_string`, `ts_tree_root_node`, `ts_tree_delete`, `ts_node_string`, `ts_parser_delete`), and is missing the functions needed to walk the AST. Before implementing the rule engine, at least the following need to be added (function names/signatures have been verified against `vendor/tree-sitter/include/tree_sitter/api.h`; per CLAUDE.md rule 1, every function listed in this section is one that actually exists in that header).

- `ts_node_type(TSNode): PAnsiChar` — the node's type name (corresponds to `type` in `node-types.json`)
- `ts_node_is_null(TSNode): Boolean`
- `ts_node_child_count(TSNode): LongWord` / `ts_node_named_child_count(TSNode): LongWord`
- `ts_node_child(TSNode; index: LongWord): TSNode` / `ts_node_named_child(TSNode; index: LongWord): TSNode`
- `ts_node_field_name_for_child(TSNode; index: LongWord): PAnsiChar` — needed to access children by field name (the keys under `fields` in `node-types.json`, e.g. `exprBinary`'s `lhs`/`operator`/`rhs`)
- `ts_node_start_point(TSNode): TSPoint` / `ts_node_end_point(TSNode): TSPoint` — used for diagnostic line/column numbers (add `TSPoint = record row, column: LongWord end;` exactly as defined in `api.h`)
- Cursor API (an optimization to avoid recomputing `ts_node_child` on every call when a node has many children; useful once large files need to be handled efficiently): `ts_tree_cursor_new`, `ts_tree_cursor_delete`, `ts_tree_cursor_current_node`, `ts_tree_cursor_current_field_name`, `ts_tree_cursor_goto_first_child`, `ts_tree_cursor_goto_next_sibling`, `ts_tree_cursor_goto_parent`

At the bootstrap stage, a naive recursive descent via `ts_node_child`/`ts_node_child_count` is sufficient; switching to the cursor API can wait until optimization is actually needed. (Owner: Sonnet5. Note that every time a function is added, per CLAUDE.md rule 1 the reference to check against is `vendor/tree-sitter/include/tree_sitter/api.h` — verify the signature each time and leave a comment citing the source.)

### 1.3 Traversal Driver (ASTWalker.pas)

A simple depth-first traversal is proposed, backed by a dispatch table keyed on node type strings.

```pascal
type
  TNodeVisitProc = procedure(const Node: TSNode; Ctx: TLintContext) of object;

// node type name -> list of VisitProcs for rules interested in that node
// (RuleRegistry lets each rule declare the node types it cares about, e.g.
//  "I only care about exprBinary and assignment," so the walker calls only
//  the relevant rules per node instead of every rule on every node. With
//  271 distinct node types, this avoids an all-rules-times-all-nodes
//  brute-force design.)
procedure WalkTree(const Root: TSNode; Ctx: TLintContext);
```

The traversal itself knows nothing about rule logic; it merely looks up the dispatch table managed by `RuleRegistry`. The goal is that adding a new rule never requires changing this file. (Owner: Sonnet5)

### 1.4 Rule Implementation Unit and Interface

The basic unit is one rule per unit (`src/Rules/RuleXxx.pas`). Rules implement the following interface.

```pascal
type
  TSeverity = (svWarning); // Room is left to add svError etc. later, but for
                           // now every rule is uniformly svWarning (per
                           // CLAUDE.md rule 5's false-positive-avoidance
                           // priority, no rule has yet been judged reliable
                           // enough to unconditionally fail CI as an error)

  IRawpacoRule = interface
    function RuleId: string;         // e.g. 'RAWPACO-SEC-001'
    function Description: string;    // one-line description (basis for the diagnostic message)
    function InterestedNodeTypes: TStringArray; // e.g. ['exprBinary', 'assignment']
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;
```

- `RuleId` follows a uniform `RAWPACO-<category>-<number>` format (example categories: `SEC` = security, `STYLE` = consistency/naming, `DEPR` = deprecated API, `DEFENSE` = excessive defensiveness, `HALLUC` = hallucination). The category exists to make it easy to trace back to the "five problems".
- Declaring `InterestedNodeTypes` lets `RuleRegistry` build the dispatch table.
- When `Check` finds a problem, it calls `Ctx.Report(RuleId, Message, Node)`. `Ctx` derives the file name/line/column from `ts_node_start_point` and assembles a `TDiagnostic`.

**On the registration mechanism (an FPC constraint)**: FPC has no runtime assembly-scanning or automatic annotation-collection mechanism. This rules out a "just drop the unit in and it's automatically active" plugin model. Instead, each rule unit needs both of:
1. Calling `RuleRegistry.Register(TRuleXxx.Create)` in its `initialization` section
2. Being listed in the `uses` clause of `Rules/AllRules.pas` (since `initialization` only runs once a unit is actually `uses`d)

This is an easy mistake to make — forgetting to add an entry to `AllRules.pas` for a new rule leaves it silently inactive — so this constraint must be documented as the "why" (CLAUDE.md rule 8) in `AllRules.pas`'s header comment. (Owner: Sonnet5)

### 1.5 Diagnostics and Context

```pascal
type
  TDiagnostic = record
    RuleId: string;
    Message: string;
    FileName: string;
    Line, Column: LongWord;   // 1-origin (to match human-facing display;
                               // ts_node_start_point is 0-origin, so +1)
    Severity: TSeverity;
  end;

  TLintContext = class
  private
    FDiagnostics: specialize TList<TDiagnostic>; // Generics.Collections
    FFileName: string;
    FSource: PAnsiChar; // The whole source. Kept so that text can be sliced
                          // out from the byte range of identifiers etc.
                          // (ts_node_string only returns a parenthesized
                          // S-expression, so when the actual token text is
                          // needed it must be sliced from the source bytes
                          // by hand)
  public
    procedure Report(const RuleId, Message: string; const Node: TSNode);
    property Diagnostics: specialize TList<TDiagnostic> read FDiagnostics;
  end;
```

Since `ts_node_string` only returns a debug S-expression representation, rules that need the actual text of an identifier name or string literal (naming-convention checks, secret-string detection, etc.) will slice a substring out of the source byte sequence using `ts_node_start_byte`/`ts_node_end_byte` (these exist in `api.h` and need to be added to `TSBindings.pas`). (Owner: Sonnet5)

### 1.6 Execution Flow (pseudocode)

```
for each target file in the paths given on the CLI:
  Source := read the file
  Tree := ts_parser_parse_string(...)
  Root := ts_tree_root_node(Tree)
  Ctx := TLintContext.Create(file name, Source)
  WalkTree(Root, Ctx)          // looks up RuleRegistry's dispatch table and calls each rule's Check
  AllDiagnostics += Ctx.Diagnostics
  ts_tree_delete(Tree)

Pass AllDiagnostics to the output formatter and print (see section 4)
ExitCode := 1 if AllDiagnostics is non-empty, 0 if empty
```

(Owner: Sonnet5)

## 2. Detection Approach per Problem (of the Five)

### 2.1 Inconsistency (naming conventions, inconsistent error handling)

- **What can be detected**: fixed naming conventions (type names prefixed with `T`, fields prefixed with `F`, etc.) can be detected just by pulling identifier names out of nodes like `declType`/`declField`/`declProc` and matching them against regex-like patterns. However, since "what the correct convention is" varies by project, the conventions themselves must not be hardcoded — they need to be definable via a config file (described later).
- **What's hard to detect**: the actual underlying problem — "error-handling conventions drift across sessions" — is a **cross-file, semantic comparison**: when the *same semantic operation* is performed in multiple places, one site wraps it in `try-except` while another leaves it bare. tree-sitter only shows individual syntax trees and cannot judge "these two `exprCall`s are semantically the same kind of operation." As a compromise, it is possible to detect mixing *within a single file* by looking only at the syntactic presence or absence of "a specific call pattern (e.g. file-I/O calls like `Assign`/`Reset`/`Rewrite`) inside vs. outside a `try` block" — this doesn't judge semantic sameness, it's a loose approximation based purely on matching surface-level API call names. This falls under CLAUDE.md rule 8's "loosened implementation to avoid false positives", so the reasoning must be documented in a comment at implementation time.
- Detecting naming-convention drift across sessions (commits) — e.g., naming changed compared to a past commit — is out of scope for single-file syntax analysis (it would need history information like `git blame`) and is not addressed by this design. It is noted as a possible future extension in "7. Open Questions".

### 2.2 Excessive Defensive Coding

- **What can be detected (low risk)**:
  - Empty `except` handlers (an exception is swallowed and nothing happens): the `body`/`children` of `exceptionHandler`/`exceptionElse` are effectively empty, or just a bare `;`. This is a broadly useful pattern that falls under both "excessive defensive coding" and "overlooked security" (swallowing an error hides the underlying anomaly) at once.
  - A meaningless nil check right after object construction: the statement immediately after `Obj := TFoo.Create(...)` is `if Assigned(Obj) then`. Since Pascal constructors never return nil (unless they raise an exception), this immediate check is always true and pointless. To avoid false positives, "immediately after" is restricted to an adjacent statement within the same `statements` block — if anything intervenes, it's excluded.
- **What's difficult to detect**: whether code "adds a large amount of edge-case handling that wasn't asked for" is something rawpaco fundamentally cannot know, since it has no access to what was actually "asked for" (requirements live in natural-language issues or PR descriptions, not in the syntax tree). This is a semantic necessity judgment that is, in principle, undetectable by syntax analysis alone. This design narrows scope to "concrete patterns that can always be safely flagged regardless of meaning" (the two above) and does not adopt vague statistical measures like "amount of defensive coding".

### 2.3 Dependency Optimism (Hallucination)

Of the five, this is the hardest to address with syntax analysis alone.

- **What's impossible in principle**: generically determining "does this unit/function actually exist?" tree-sitter-pascal has neither a symbol table nor type information, and rawpaco itself does not query package registries over the network (which also matches the requirement, from its CI use case, that it should work offline).
- **In practice, many cases are already caught by CI's `make` (compilation via `fpc`)**: nonexistent identifiers and argument-type mismatches are already caught by CI as compile errors. So it's realistic for rawpaco to focus on cases the compiler cannot catch — code that compiles fine but picks a real, existing API that's simply the wrong one for the job.
- **Alternative approaches (partially achievable)**:
  1. **Bundle a symbol list for FPC's standard units**: extract the list of identifiers publicly exposed by major units like `SysUtils`/`Classes` from the `fpc-source` of the pinned FPC version, and ship it in the repository, version-tagged, as something like `data/fpc-rtl-symbols.json` (the same idea as pinning the tree-sitter-pascal version — CLAUDE.md rule 2). Whenever a unit name obtained from a target file's `declUses` is a known unit in this bundled list, cross-check whether a bare identifier call reached via `exprDot` (`SysUtils.Foo` style) or via `uses` actually exists in that unit's symbol list. If it doesn't match, flag it as "an identifier that doesn't exist in the bundled SysUtils/Classes/etc."
     - This approach is **limited to known RTL/FCL units**; user-defined types/classes and third-party packages (Indy, mORMot, etc.) are out of scope (bundling their sources would be impractical to begin with). Note explicitly that this approach cannot cover the central example given in the original request — "mistaken argument names for a minor third-party API."
     - Since no scope resolution is performed, this cannot accurately reproduce name-resolution precedence when `uses` lists multiple units (e.g. a later unit shadowing an earlier one). To keep false positives down, this uses a one-directional, loose implementation that only warns when "the identifier isn't found in the symbol list of *any* of the used units."
     - Designing the symbol-extraction pipeline itself (parsing `fpc-source`'s Pascal sources to pull out symbol names), deciding the format, and designing how loose the name resolution should be, are all high-difficulty tasks, so **Owner: Opus5**.
  2. **Manually grow a "known-hallucinated API blocklist"**: accumulate a small list of "plausible-sounding but nonexistent FPC API names" actually observed in the wild (e.g., someone mistakenly believing `TStringHelper.Contains` is available in FPC), and detect them by exact match. Low maintenance cost, low coverage — a pragmatic compromise. (Owner: Sonnet5, though a human/Opus review is recommended for deciding what goes in the initial list)
- Errors at the level of "fine-grained argument names for minor libraries/APIs," as mentioned in the original request, require type and argument-list resolution, and are explicitly stated to be **undetectable** within the scope of this design.

### 2.4 Overlooked Security

- The example given in the original request (overly broad IAM policies) targets cloud infrastructure definitions (IaC) and doesn't directly apply to desktop/server-side Pascal code. As syntactically-safe alternative patterns detectable in a Pascal context, this narrows down to the following two:
  1. **SQL string-concatenation pattern**: warn when an `exprBinary`'s `operator` is `+` (string concatenation), one of `lhs`/`rhs` is a `literalString` containing a SQL keyword (`SELECT`/`INSERT`/`UPDATE`/`DELETE`/`WHERE`/`FROM`, etc., case-insensitive), and the other side is anything other than a `literalString` (i.e. a variable or expression). This is a proven heuristic also adopted by static analysis tools for other languages (e.g. Bandit's B608). Parameterized queries (in the form `Params.ParamByName(...).AsString := X`) don't involve concatenation, so they're not falsely flagged.
  2. **Hardcoded secret-looking strings**: warn when the left-hand identifier name of a `varDef`/`declVar`/`declConst`/`assignment` matches a pattern like `password`/`secret`/`apikey`/`api_key`/`token`/`connectionstring` (case-insensitive, substring match) and the right-hand side is a non-empty `literalString`. Obvious placeholders like `CHANGE_ME`/`YOUR_API_KEY_HERE`/an empty string are excluded to curb false positives (the exclusion list is a small fixed list in the initial implementation, leaving room to make it configurable later).
  3. **Swallowed exceptions** (already covered in 2.2) also count, doubly, from a security angle (hiding an anomaly). Its category is primarily `RAWPACO-DEFENSE-*`, but this design doc also treats it as one facet of security.

### 2.5 Outdated Practices (Deprecated APIs from Stale Training Data, etc.)

- CLAUDE.md rule 1 itself is rawpaco's own countermeasure against this problem during its own development (checking freepascal.org beforehand); this section is about detecting outdated practices in **the code rawpaco analyzes**.
- FPC's RTL/FCL sources often mark deprecated identifiers with the language-standard `deprecated;` or `deprecated 'message';` directive, and tree-sitter-pascal's grammar has a corresponding `kDeprecated` token (confirmed in `node-types.json`). The natural design is to extend the RTL symbol-extraction pipeline from 2.3 to also extract "the list of identifiers marked `deprecated`" at the same time, and warn when target code calls one of them. The version of the `fpc-source` package used as the extraction source is kept in sync with the CI environment's FPC version, managed under a pinning policy (the same idea as CLAUDE.md rule 2).
- The case where target code marks its own declared procedure/function as `deprecated` yet keeps calling it normally within the same file (self-contradiction) can be detected purely from the syntax tree, with no extra symbol extraction needed (just check whether a `declProc`'s `attribute` has `kDeprecated` via `procAttribute`, and cross-check that identifier name against the `entity` of `exprCall`s in the same file). This is a low-cost byproduct to implement.
- "Current best practice" (e.g., information that a newer FPC version added a safer alternative API) cannot be detected in cases that aren't marked deprecated (an "implicitly outdated" style with no `deprecated` directive attached is out of scope).

### 2.6 Summary Table

| # | Problem | Detectable by syntax analysis alone? | Adopted fallback / scope |
|---|---|---|---|
| 1 | Inconsistency | Naming conventions: yes (needs config file). Semantic consistency of error handling: no (only a same-file, surface-API-match approximation) | See 2.1 |
| 2 | Excessive defensive coding | Judging "amount": no. Specific pointless patterns (empty except, nil check right after construction): yes | See 2.2 |
| 3 | Hallucination | General existence-checking: no (needs type/registry info). Cross-checking against known RTL/FCL symbols: partially yes | See 2.3. Third-party APIs out of scope |
| 4 | Overlooked security | The original example (IAM) doesn't apply to Pascal. SQL concatenation / hardcoded secrets: yes | See 2.4 |
| 5 | Outdated practices | Usage of APIs marked `deprecated`: yes. Implicit staleness with no mark: no | See 2.5 |

## 3. Placement and Execution of positive/negative Samples

To stay consistent with CLAUDE.md rule 3 (both positive and negative required), the following convention is adopted (the key points are also noted in `tests/README.md`).

- Placement: `tests/positive/<RuleId>/*.pas`, `tests/negative/<RuleId>/*.pas`. Multiple files per rule are fine (add more as variations come up).
- Execution: set up a new `tests/run_tests.sh` that does the following.
  1. For each `.pas` under `tests/negative/<RuleId>/`, run `./src/rawpaco <file>` and confirm the output contains `<RuleId>` (fail the test if it doesn't).
  2. For each `.pas` under `tests/positive/<RuleId>/`, run the same and confirm the output **does not** contain `<RuleId>` (fail the test if it does — i.e. a false positive).
  3. Add a `test` target to the `Makefile` so `make test` runs everything at once. Add a `make test` step (or the equivalent shell command on the Windows side) to both `build-linux`/`build-windows` in CI (`.github/workflows/ci.yml`).
- Why a shell script: introducing a unit-testing framework for FPC (fpcunit etc.) was an option, but since rawpaco is a self-contained CLI and its I/O (exit code, stdout string matching) is enough to verify it, this adopts a self-contained bash-on-CI approach with no added dependency. This leaves the door open to migrating to fpcunit later if the number of rules grows and assertions get more complex. (Owner: Sonnet5)

## 4. Diagnostic Output Format

**Implementation status note (2026-08-04, found during review)**: the `--format` option, `github`/`json` output, and the "inline suppression comment" (`// rawpaco:ignore`) designed in this section all remain unimplemented, even after P1–P9 and `--only`/`--exclude` were completed. The only format actually implemented is `text` (`src/Diagnostics.pas`'s `FormatDiagnosticText`), and the only options `src/rawpaco.lpr` accepts are `--config`/`--only`/`--exclude`. See HANDOFF.md's "Not yet started / pending" section for details.

With GitHub Actions usage as the primary target, the following three formats are supported (via a `--format` option, defaulting to `text`).

- `text` (default, human-readable): `<file>:<line>:<column>: warning: <message> [<RuleId>]` (a format modeled on gcc/eslint-style tools)
- `github`: emits one line per diagnostic in GitHub Actions' workflow-command format, `::warning file=<file>,line=<line>,col=<column>::[<RuleId>] <message>`. This attaches inline annotations directly to the PR diff view.
- `json`: an array of `[{"ruleId":..,"file":..,"line":..,"column":..,"severity":..,"message":..}, ...]`. A machine-readable format anticipating integration with other tools and, potentially, the GitHub Annotations API in the future.

**Exit code**: `1` if there is even a single diagnostic, `0` if there are none. As the flip side of CLAUDE.md rule 5 (prioritize avoiding false positives), the policy is that once something has been adopted as a rule, "warning = needs fixing" is meant to be a strong signal; exit-code control weighted by warning/error severity (e.g. letting warnings through) is not introduced for now (severity-based threshold control is noted as a future extension candidate in section 7).

**Inline suppression comment**: to handle individual false positives and deliberate exceptions, if `// rawpaco:ignore <RuleId>` appears on the target line or the line immediately before it, the diagnostic for that `RuleId` on that line is suppressed. Working from the premise that false positives can never be reduced to zero (CLAUDE.md rule 5 says "prioritize avoiding," not "guarantee"), this was judged essential as an escape hatch so the tool can realistically be run as a CI blocker. The recommended operating rule when using a suppression comment is to also note "why it's being suppressed"; this is something that could be added to `README.md`/`CLAUDE.md` in the future (this design doc only proposes it). (Owner: Sonnet5)

## 5. Path to Integrating Self-Linting (the Chicken-and-Egg Problem)

CLAUDE.md rule 4 — "add a CI step that lints the tool's own source and keeps it at zero warnings" — cannot yet be added to CI while there isn't a single rule (as HANDOFF.md's current notes say). This is resolved in the following order.

1. Implement the first rule (following the priority order in section 7) and verify it with positive/negative samples.
2. **Locally**, run `./src/rawpaco src/*.pas` and check rawpaco's own source for false positives/true positives.
   - If a true positive (something that genuinely should be fixed) is found, fix it while leaving a reason comment per CLAUDE.md rule 8.
   - If it's a false positive, revisit the rule's own logic (don't casually paper over it with a section-4 suppression comment — suppression comments are for "deliberate exceptions," not for hiding a bug in the rule).
3. In order, for each rule confirmed clean in step 2, add a step to both the `build-linux`/`build-windows` jobs in CI (`.github/workflows/ci.yml`) that "lints its own source and confirms the exit code is 0." There's no need to wait until all rules are done starting from zero rules — clean rules can be added to the self-lint target incrementally (e.g., by providing an option like `rawpaco --only=RAWPACO-SEC-001 src/*.pas` that enables only a specific rule, to explicitly control the scope of self-linting).
4. Once all rules pass self-linting, drop the `--only` restriction and move to self-linting against the full set.
5. Update HANDOFF.md's "Self-lint progress" section each time, in step with progress on each of the above.

`--only`/`--exclude` options were judged essential for this incremental rollout, and it's recommended they be prepared early, alongside the rule implementations in section 7. (Owner: Sonnet5)

## 6. Implementation Priority and Concrete Proposals for the First Several Rules

Prioritized by how easy it is to avoid false positives, implementation simplicity, and value. P1–P3 are self-contained syntactic patterns that are safe with high confidence; P4 onward requires additional design elements such as config files or data pipelines.

### P1: RAWPACO-DEFENSE-001 Empty except handler (swallowed exception)

- Detection target: the body of `exceptionHandler`/`exceptionElse` is effectively empty (just `;`, or no child nodes).
- Corresponding problem(s): both #2 (excessive defensiveness) and #4 (security — hiding an anomaly).
- False-positive risk: low (a deliberately silent catch block that doesn't even log is almost always code that should be revisited).
- Owner: Sonnet5

### P2: RAWPACO-SEC-001 SQL string-concatenation pattern

- Detection target: see 2.4 item 1. An `exprBinary`'s `+` operator where one side is a `literalString` containing a SQL keyword and the other is not a literal.
- False-positive risk: moderate (may pick up string concatenation that merely looks like SQL, e.g. a log message). Requires tuning such as matching keywords at word boundaries and limiting the keyword list to ones that aren't overly generic, like `WHERE`/`SELECT`.
- Owner: Sonnet5

### P3: RAWPACO-SEC-002 Hardcoded secret-looking strings

- Detection target: see 2.4 item 2.
- False-positive risk: moderate (the placeholder exclusion list needs tuning).
- Owner: Sonnet5

### P4: RAWPACO-DEPR-001 Self-contradictory deprecated-API usage (within the same file)

- Detection target: the case from 2.5 where target code keeps calling its own `deprecated`-declared procedure within the same file. Self-contained via the syntax tree alone, no external data needed.
- False-positive risk: low.
- Owner: Sonnet5

### P5: RAWPACO-STYLE-001 Naming-convention check (config-file based)

- Detection target: see 2.1. Type names prefixed `T`, fields prefixed `F`, etc.
- What's hard: ambiguous specification judgment calls, such as how to express the rules (regex-based, or declarative prefix/suffix specification?), what defaults to use for a project that hasn't specified any rules, and where to draw the line between conventions that are broadly agreed upon in the FPC/Lazarus community and those that aren't.
- Owner: **Opus5** (config-file schema design and default-rule selection. Once the schema is finalized, the mechanical AST-matching part can also be implemented by Sonnet5)

### P6: RAWPACO-DEPR-002 Detection based on FPC RTL/FCL's list of `deprecated` symbols

- Detection target: section 2.5. Premised on a pipeline that extracts `deprecated` identifiers from `fpc-source`.
- What's hard: designing the extraction pipeline itself (lightweight parsing of Pascal sources, selecting target units, version management/regeneration procedure, how to vet the impact on existing rules).
- Owner: **Opus5**

### P7: RAWPACO-HALLUC-001 Cross-checking against FPC RTL/FCL's list of known symbols

- Detection target: alternative approach 1 from 2.3.
- What's hard: on top of the symbol-list extraction pipeline (shareable with P6), designing the one-directional, loose name-resolution logic based on the `uses` clause.
- Owner: **Opus5**

### P8: RAWPACO-DEFENSE-002 Meaningless nil check right after construction

- Detection target: see 2.2.
- False-positive risk: depends on how "immediately after" is scoped. Start narrow, with only the directly-following statement within the same `statements` block.
- Owner: Sonnet5

### P9: RAWPACO-STYLE-002 Inconsistent error handling within the same file (approximation)

- Detection target: the "loose approximation" idea from 2.1 — a mix of call sites where the same kind of API call is try-protected in some places and not in others.
- What's hard: how to define "the same kind of API call" (limit to exact call-name matches, or narrow it to calls reachable from specific units seen in `declUses`?), and estimating the false-positive rate.
- Owner: **Opus5**

## 7. Open Questions / Proposals (things that could be major policy shifts, not decided unilaterally)

The following were noticed during this review but amount to deleting existing rules or drastically changing scope, so they are left as proposals rather than decided outright.

- **Detecting naming-convention/idiom drift across sessions (commit history)**: as noted in 2.1, this is fundamentally out of reach for single-file syntax analysis. There's room to consider a future "rawpaco extended mode" that integrates with `git log`/`git blame` and aggregates across multiple files/commits, but this would change rawpaco's character from a "static analysis tool" to a "repository analysis tool," so it would need a fresh design decision if ever pursued.
- **Severity-based (warning/error) exit-code control**: section 4 kept things simple with "exit code 1 for even one diagnostic," but as operation matures and the number of rules grows, there may be a desire for graduated severity control — "this rule is just a heads-up, don't fail CI for it." At the time of writing there are zero rules, so the need for this can't yet be judged, and introducing it is deferred.
- **Writing the suppression-comment operating rule into CLAUDE.md/README.md**: the operating rule mentioned in section 4 — "write a reason when using a suppression comment" — is in the spirit of CLAUDE.md rule 8 (comments preserve the "why"), but adding to CLAUDE.md itself amounts to establishing a new rule, so this was left as a proposal rather than done in this session.
- **Broadening CLAUDE.md rule 1's scope to "external C libraries in general"** (a further generalization beyond the small edit already made in this session): this session only made the minimal clarification that "tree-sitter's API is also covered." If the possibility of adding other external C libraries comes up in the future, consider generalizing the rule's wording further.

## 8. Owner Assignment Summary

| Item | Owner |
|---|---|
| ASTWalker (traversal driver) | Sonnet5 |
| TSBindings.pas extension (adding node-traversal functions) | Sonnet5 |
| RuleRegistry, rule interface definition | Sonnet5 |
| Diagnostics (TDiagnostic, text/github/json output formatter) | Sonnet5 |
| Suppression-comment (`rawpaco:ignore`) mechanism | Sonnet5 |
| tests/run_tests.sh, Makefile `test` target | Sonnet5 |
| `--only`/`--exclude` options | Sonnet5 |
| P1 RAWPACO-DEFENSE-001 (empty except) | Sonnet5 |
| P2 RAWPACO-SEC-001 (SQL string concatenation) | Sonnet5 |
| P3 RAWPACO-SEC-002 (hardcoded secrets) | Sonnet5 |
| P4 RAWPACO-DEPR-001 (self-contradictory deprecated usage) | Sonnet5 |
| P5 RAWPACO-STYLE-001 (naming conventions, config-file schema) | **Opus5** (schema/default rules) / Sonnet5 (AST-matching implementation once the schema is finalized) |
| P6 RAWPACO-DEPR-002 (RTL deprecated-symbol extraction) | **Opus5** |
| P7 RAWPACO-HALLUC-001 (RTL symbol cross-check hallucination detection) | **Opus5** |
| P8 RAWPACO-DEFENSE-002 (nil check right after construction) | Sonnet5 |
| P9 RAWPACO-STYLE-002 (approximate inconsistent-error-handling detection) | **Opus5** |
