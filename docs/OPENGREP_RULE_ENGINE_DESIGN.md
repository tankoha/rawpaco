# Bringing the opengrep Rule Engine into rawpaco: Feasibility Study and Design

- Created: 2026-11-16
- Status: study and design document (implementation not started; no source code was changed)
- Subjects studied: opengrep/opengrep `main` at commit `526deafe` (2026-11-13); rawpaco at commit `ffb5c9c`
- Language: this English version is canonical. `docs/OPENGREP_RULE_ENGINE_DESIGN_jp.md` is the Japanese reference copy; update this file first (HANDOFF.md convention)
- Decisions (2026-11-16, owner): proceed with option (d). The document follows the `docs/` naming convention with English as canonical (items 1 and 2 of Section 10 are settled)

This document labels the strength of each claim:

- **[Measured]** verified in this study by actually running commands
- **[Source-checked]** verified by reading the opengrep or rawpaco source
- **[Unverified]** prior knowledge or inference; must be confirmed before implementation

---

## 0. Conclusion and Recommendation

**Conclusion: "partially feasible". Bringing in "the whole thing" is close to impossible as a rawpaco integration and is not recommended.**

1. **Bringing in opengrep itself does not let it analyze Pascal.** opengrep's supported languages do not include Pascal/Delphi [Source-checked]. The engine does not run on tree-sitter CSTs but on a Generic AST produced by a hand-written per-language translator. Whether opengrep is linked in or called as an external process, unless someone writes a Pascal translator (in OCaml), only the syntax-unaware `generic` / `regex` modes are usable.
2. **Re-implementing every feature in FPC is out of proportion.** The engine core of opengrep (rules, matching, search, taint, IL, analysis, naming, autofix, Generic AST definition) is about 69,000 lines of OCaml [Measured]. rawpaco as a whole is about 5,800 lines [Measured]. Taint mode alone is about 19,000 lines and depends on IL, CFG, dataflow, constant propagation, and name resolution.
3. **What is realistic is "re-implement a subset of the rule language in FPC and run it directly on the tree-sitter-pascal CST".** Search mode (`pattern` / `patterns` / `pattern-either` / `pattern-not` / `pattern-inside` / `pattern-not-inside` / `pattern-regex` / `metavariable-regex` / `metavariable-pattern` / `focus-metavariable`, metavariables, ellipsis) is very likely implementable. Pattern fragments were confirmed to parse with tree-sitter-pascal, given wrappers and preprocessing [Measured, Section 4.2].

**Recommendation (adopted 2026-11-16): introduce option (d), "FPC re-implementation of an opengrep-compatible subset", incrementally as a "declarative rule layer" alongside the existing native rules.**

- In scope: the main search-mode operators, metavariables, ellipsis, message interpolation, SARIF output, and later autofix via `fix:`
- Out of scope: taint mode, join mode, inter-file analysis, typed metavariables, constant/symbol propagation, SCA, extract mode, generic (spacegrep/aliengrep) mode
- The existing 13 rules are not replaced. Custom analyses like MEM-001 and HALLUC-001 cannot be expressed in the pattern language

**Three honest caveats.**

- The result is "a Pascal dialect of the opengrep rule format", not opengrep itself. opengrep does not know `languages: [pascal]`, so rawpaco rule files cannot be run on opengrep to compare behavior. **Compatibility cannot be verified mechanically** (Section 7).
- No existing Semgrep/opengrep rules target Pascal. So there is no "existing rules just work" benefit. What is gained is "rules can be written in YAML instead of Pascal code".
- If "really every feature (including taint)" is required, the only realistic path goes the other way: **add Pascal language support to opengrep** (option b', Section 2.3). That is a separate OCaml project outside rawpaco's development rules (FPC implementation, false-positive avoidance first). This was listed for the owner's decision in Section 10.

---

## 1. Structure of the opengrep Rule Engine

### 1.1 Overview [Source-checked]

opengrep is a fork of Semgrep CE, implemented in OCaml 5.3 (`OPENGREP.md`). License: LGPL-2.1 (`LICENSE` / `COPYRIGHT`). Self-contained binaries are distributed for Linux / macOS / Windows (`README.md`).

The processing flow:

```
rule YAML ──(Parse_rule)──> Rule.t (tree of formulas)
target source ──(per-language parser)──> per-language CST/AST ──(per-language translator)──> Generic AST
pattern string ──(same per-language parser, grammar extended for metavariables/ellipsis)──> Generic AST
        Generic AST vs Generic AST via Generic_vs_generic ──> set of (range, metavariable bindings)
        formulas combined by range operations (Match_search_mode) ──> findings
        taint mode: Generic AST → IL → CFG → dataflow (src/tainting)
```

The key point is that **the matcher does not look at the tree-sitter tree directly**. Each language has a hand-written translator `Parse_<lang>_tree_sitter.ml` that absorbs syntactic variation (parentheses, syntactic sugar, etc.) before matching.

### 1.2 Size [Measured]

Line counts of `.ml` files (including tests, excluding `.mli`).

| Directory | Lines | Role |
|---|---:|---|
| `src/rule` | 2,128 | Rule data types (`formula` in `Rule.ml`, etc.) |
| `src/parsing` | 5,257 | Rule YAML parsing (`Parse_rule.ml` etc.) |
| `src/matching` | 7,258 | Pattern matching. `Generic_vs_generic.ml` alone is 4,314 lines |
| `src/engine` | 10,371 | Driving search/taint modes, metavariable conditions, range operations |
| `src/tainting` | 19,006 | Taint analysis (function signatures, shapes, fixpoint, etc.) |
| `src/il` | 1,956 | Intermediate language |
| `src/analyzing` | 9,415 | CFG, dataflow, constant propagation, etc. |
| `src/naming` | 3,418 | Name resolution |
| `src/fixing` | 1,302 | Autofix |
| `src/call_graph` | 1,648 | Call graph |
| `libs/ast_generic` | 7,238 | Generic AST definition |
| **Total** | **~69,000** | Excludes language front ends, CLI, output, SCA, etc. |

Size of one language front end for reference: Lua translator 824 lines; Ruby 2,585 + 1,036 lines; the hand-written VB.NET parser 5,935 lines.

### 1.3 Elements of the Rule Language [Source-checked]

`formula_kind` in `Rule.ml` is `P` (leaf pattern) / `And` / `Or` / `Not` / `Inside` / `Anywhere`, plus conditions (`CondEval` / `CondRegexp` / `CondType` / `CondAnalysis` / `CondNestedFormula` / `CondName`, etc.) and `focus`. Leaf patterns (`Xpattern.ml`) are of four kinds: `Sem` (syntactic pattern) / `Spacegrep` / `Aliengrep` / `Regexp`. Modes are `search` / `taint` / `extract` / `steps` / `sca`.

Keys accepted by the rule parser: `pattern` `patterns` `pattern-either` `pattern-not` `pattern-inside` `pattern-not-inside` `pattern-regex` `pattern-not-regex` `metavariable-regex` `metavariable-pattern` `metavariable-comparison` `metavariable-type` `metavariable-analysis` `focus-metavariable` `fix` `fix-regex` `pattern-sources` `pattern-sinks` `pattern-sanitizers` `pattern-propagators`.

The combination semantics are operations on pairs of "range and metavariable bindings" (`Range_with_metavars.ml`). Filtering uses range inclusion and binding compatibility; negations differ by kind (`pattern-not-inside` uses inclusion, `pattern-not` uses range equality, regexes accept inclusion in either direction). Statement-sequence matching has options `go_deeper_stmt` (descend into nested blocks) and `go_deeper_expr` (descend into sub-expressions).

### 1.4 Not Verified [Unverified]

- Where join mode is implemented. The CHANGELOG mentions `join_rule`, so the feature exists, but whether it lives on the OCaml or Python side was not traced. Prior knowledge says it was on the Python side in Semgrep
- Whether JSON is accepted as a rule file. Prior knowledge says Semgrep accepts it, but this commit was not checked
- The license of the opengrep rule set (opengrep-rules). Irrelevant here since there are no Pascal rules

---

## 2. Comparing Ways to "Bring In Everything"

### 2.1 Summary

| Option | Description | Technically feasible | Can parse Pascal syntactically | Size | Verdict |
|---|---|---|---|---|---|
| (a) | Link/bundle the OCaml engine as a library | Extremely hard | No (no translator) | Huge | **Rejected** |
| (b) | Call opengrep as an external process | Yes | No (`generic` / `regex` only) | Small | OK as an auxiliary; does not answer this request |
| (b') | Add Pascal support to opengrep and use it as an external process | Yes | Yes | Large (OCaml) | The only path if "everything" is mandatory. Separate project |
| (c) | Re-implement the entire rule language and semantics in FPC | Practically impossible | Yes | Huge (~69k lines equivalent) | **Rejected** |
| (d) | Re-implement a subset in FPC and run it on the CST | Yes | Yes | Medium | **Recommended (adopted)** |
| (e) | Use tree-sitter queries (`.scm`) as a declarative rule format | Yes | Yes | Small | Alternative. Unrelated to opengrep |

### 2.2 Option (a): Linking the OCaml Engine

Rejected, because:

- **There is no Pascal front end, so linking it analyzes nothing.** The same OCaml translator as in (b') would be needed anyway.
- **It is incompatible with the Windows build.** rawpaco's Windows CI is settled on 32-bit (i386-win32); the 64-bit path was examined and abandoned (HANDOFF.md). OCaml 5.x has no 32-bit native code generation [Unverified, prior knowledge]. opengrep requires OCaml 5.3, so it cannot be linked into 32-bit rawpaco.
- **Linking is hard.** The OCaml runtime (GC, OCaml 5 domains), PCRE2, and opengrep's own tree-sitter runtime would have to go through the FPC linker. That tree-sitter runtime would clash symbol-wise with the v0.24.7 that rawpaco pins under `vendor/`. Given that getting just the mingw runtime through took 18 CI round trips (HANDOFF.md), the outlook is poor.
- **It does not fit CLAUDE.md rule 1.** cdecl declarations must be checked against headers under `vendor/`, but opengrep has no public C API or headers. Custom C stubs would be needed, with nothing to check against.
- **License.** Distributing an executable that statically links LGPL-2.1 code obliges providing a means for users to replace the library part and relink (e.g. object files) (section 6). rawpaco is MIT and is currently a single statically linked binary.

### 2.3 Options (b) and (b'): External Process

**(b) Call as-is.** opengrep can handle `.pas` only with `languages: [generic]` or `[regex]` [Source-checked: `Xlang.ml`]. These do not understand Pascal syntax, comments, strings, or case insensitivity, so precision is lower than rawpaco with tree-sitter-pascal. It fits poorly with CLAUDE.md rule 5 (false-positive avoidance first). There is little value in embedding it in rawpaco; users can run it side by side as a separate tool. Process separation means no license impact.

**(b') Add Pascal to opengrep.** Required work [Unverified, prior knowledge of Semgrep's language-addition procedure]:

1. Create a derived tree-sitter-pascal grammar extended to accept metavariables and ellipsis
2. Generate OCaml CST types from that grammar
3. Write a CST → Generic AST translator in OCaml (`grammar.js` is 1,206 lines, so estimated at Ruby-level 2,000–4,000 lines)
4. Register the language, write tests, propose upstream or maintain a fork

If that works, **truly everything** including taint and autofix is available. However it departs from rawpaco's policies:

- The implementation language becomes OCaml, outside rawpaco's "written in FPC itself" premise
- Deriving the grammar means two grammar lines under CLAUDE.md rule 2's version pinning
- rawpaco cannot control the precision policy. Handling of Pascal-specific traps (`with`, `{$IFDEF}`, macros, paren-less calls) would live inside the Generic AST translator
- Distribution becomes two binaries

### 2.4 Option (c): Re-implement Everything in FPC

Rejected. It amounts to porting ~69k lines of OCaml, from a source under active change (the latest commit at study time was three days old). Taint rests on IL, CFG, dataflow, name resolution, and constant propagation, and for Pascal would further need type information and cross-unit resolution to be precise. rawpaco is designed without type information or a symbol table (`docs/RULE_ENGINE_DESIGN.md` Section 2.3).

Note that porting by transcribing OCaml source into Pascal creates an LGPL-2.1 derivative, which cannot be MIT (Section 3).

### 2.5 Option (d): Subset Re-implementation (Recommended, Adopted)

Designed from Section 4 on. The boundary is in Section 2.7.

### 2.6 Option (e): tree-sitter Queries

The vendored `api.h` has `ts_query_*` APIs [Source-checked]. Turning S-expression queries into a rule format would give declarative rules without writing a pattern parser. However, metavariable unification (same `$X` refers to the same thing), statement-sequence ellipsis, and boolean combination would still have to be added, and rules would read as lists of node type names rather than Pascal code fragments. The request is about the opengrep rule engine, so this document does not adopt it, but records it as a fallback if (d)'s pattern preprocessing runs into trouble.

### 2.7 Boundary: What Is Realistic

| Category | Feature | Judgment |
|---|---|---|
| In (M1–M3) | `pattern` / `patterns` / `pattern-either` / `pattern-not` / `pattern-inside` / `pattern-not-inside` | Implementable on the CST |
| | `pattern-regex` / `pattern-not-regex` / `metavariable-regex` | Regex dialect differences (Section 4.6) |
| | `metavariable-pattern` / `focus-metavariable` | Implementable |
| | Metavariables `$X`, `$_`, ellipsis `...`, named ellipsis `$...ARGS`, string `'...'`, deep expression `<... e ...>` | Implementable; needs preprocessing (Section 4.2) |
| | `$X` interpolation in `message`, `severity`, `metadata`, `paths` | Implementable |
| In (M4) | `metavariable-comparison` | Limited to integer/string literals and simple comparisons. No full evaluation of Python-like expressions |
| | `fix:` (text-replacement autofix), `fix-regex` | Implementable. Default: suggest only, do not apply |
| | `metavariable-analysis` entropy | Easy but low priority |
| Out | Taint mode (`pattern-sources` etc.) | Needs IL, CFG, dataflow. Would not be opengrep-compatible |
| | Join mode, inter-file analysis, `steps` | Outside the current per-file architecture |
| | Typed metavariables, `metavariable-type` | No type information |
| | Constant propagation, symbol propagation, alias equivalence | No name resolution; a source of false positives |
| | `extract` / `sca` / secret validation | Out of scope |
| | `generic` (spacegrep / aliengrep) mode, other languages | Unneeded for a Pascal-only tool (consistent with CLAUDE.md rule 6) |

On taint: a simple intra-procedural version (just following assignments) might someday be built as a rawpaco-specific feature, but it is different from opengrep's taint mode and should not use the same key name (`mode: taint`). It is not on this roadmap; it remains an open item.

---

## 3. License

Not legal advice. Listed as points to check before deciding on the distribution form.

- rawpaco: MIT [Source-checked: `LICENSE`]. The vendored tree-sitter and tree-sitter-pascal each ship their `LICENSE`
- opengrep: LGPL-2.1 [Source-checked]

| Option | License implications |
|---|---|
| (a) Linking | LGPL-2.1 obligations apply to the distribution (relinking means, license text and copyright notices). rawpaco's own source can stay MIT, but this fits poorly with the current single static binary |
| (b) (b') External process | No effect on rawpaco. Redistributing the opengrep binary bundled means following LGPL-2.1 for that part. The (b') translator is an opengrep derivative, hence LGPL-2.1 |
| (c) (d) Re-implementation | As long as the rule format and semantics (the "specification") are implemented independently, it is believed to stay MIT. However, **transcribing or literally porting opengrep's OCaml code creates a derivative** |

Proposed operating rules for (d):

- Implement from the publicly documented specification and our own tests. Do not work by porting while looking at the opengrep source
- Do not copy opengrep's test data (rules and targets under `tests/`) into the rawpaco repository
- Section 1 of this document is the result of reading the source to confirm behavior and contains no copied code

---

## 4. Design

### 4.1 Architecture

```
                 ┌───────── existing (minimal changes) ─────────┐
rawpaco.lpr ──> LintDriver.RunLint ──> ASTWalker ──> RuleRegistry ──> 13 native rules
   │                                                     ▲
   │ --rules=<file|dir>                                  │ registered as IRawpacoRule
   ▼                                                     │
RuleFile (loader) ──> declarative rule (formula tree) ──> DeclRule (adapter)
   │                         │
   │                         ├─ PatLexer    preprocessing of pattern strings
   │                         ├─ PatCompiler parse with tree-sitter-pascal, convert to pattern IR
   │                         ├─ PatMatcher  match pattern IR against target CST
   │                         ├─ Formula     boolean combination via range ops, metavariable conditions
   │                         └─ Regex       regex leaves and conditions
   ▼
Diagnostics (text / github / json, plus sarif)
```

New units are expected under `src/Decl/` (requires additions to `-Fu` and `RULE_SOURCES` in the `Makefile` and to the `fpc` invocation in Windows CI).

### 4.2 Pattern Parser

Patterns are parsed with the same tree-sitter-pascal as targets (pinned at v0.10.2). The grammar is not modified. This choice keeps CLAUDE.md rule 2; the opengrep approach of "extending the grammar for metavariables" is not taken. Instead, string substitution before parsing and wrappers absorb the differences.

The following results were confirmed with a verification program built with gcc from the sources under `vendor/` [Measured].

**(1) Code fragments cannot be parsed as-is.**

| Input | Result |
|---|---|
| `X := TFoo.Create;` | `ERROR` directly under the root |
| `Foo(A, B);` | `ERROR` |
| `A + B` | `ERROR` |
| `begin X := TFoo.Create; end` | No error. `blockTr` > `assignment` |
| `begin __W := A + B end` | No error. `rhs` of `assignment` is `exprBinary` |
| `procedure Foo; begin X := 1; end;` | No error. `defProc` |
| `var X: Integer = 1;` / `type TFoo = class ... end;` / `uses A, B.C;` | No error. `declVars` / `declTypes` / `declUses` respectively |

Therefore try wrappers in this order and adopt the first result that contains no `ERROR` or `MISSING`:

1. As-is (declaration-level patterns)
2. `begin <P> end` (statements, statement sequences)
3. `begin __rawpaco_w__ := <P> end` (expressions)
4. `begin try except <P> end end` (a single exception handler such as `on $V: $T do ;`; **added in M1, 2026-11-19**). Handlers can only appear inside `except` and parse as neither statements nor expressions, yet a rule must be able to target one handler among several (the M1 done condition needed it). Accepted only when the `except` part holds exactly one `exceptionHandler`; the pattern IR is that handler node, so it matches wherever such a handler appears. A list of handlers is a sequence pattern and waits for M2

A pattern that parses with none of them is a rule-load error (exit code 2). It is not silently disabled (same policy as unknown keys in `rawpaco.json`).

If wrapper 2 yields a tree that is "a single `statement` holding only an expression", treat it as an expression pattern, so that a pattern `Foo($X)` matches both a call in statement position and a call inside an expression.

**(2) `$X` collides with hexadecimal literals.**

| Input | Result |
|---|---|
| `begin $ABC := 1; end` | No error, but `$ABC` becomes **`literalNumber`** (hexadecimal) |
| `begin X := $OBJ; end` | `ERROR` |
| `begin $X := $Y.Create; end` | `ERROR` |

In Pascal `$FF` is a hexadecimal literal, so metavariables cannot go through the grammar as-is. Preprocessing substitutes as follows:

- `$` followed by a name starting with an uppercase letter or underscore → metavariable. Replace with identifier `__rawpaco_mv_<name>__`
- `$` followed by a digit-led sequence → hexadecimal literal. Leave as-is (writing `$0FF` always means hexadecimal)
- **Names made only of hexadecimal digits (`A`–`F` and digits), such as `$ABC` or `$FACE` → ambiguous, so a load error.** The message suggests renaming to `$X` or writing `$0ABC`. **Decided (#3, 2026-11-17):** a rule may set the rawpaco-specific option `options: { pascal_hex_dollar: true }`; in that rule such names are kept as hexadecimal literals (faithful to Pascal lexing) and the loader prints a one-line warning to stderr for each one instead of failing

The third rule is incompatible with opengrep (where `$A` and `$E` are ordinary metavariable names). Guessing either way would silently run a rule with a different meaning, so it is an error.

The preprocessor is written as a small scanner that skips Pascal string literals and comments, since `$X` and `...` inside strings must not be substituted.

**(3) Ellipsis `...` also needs substitution.**

| Input | Result |
|---|---|
| `begin Foo(...); end` | `ERROR` |
| `begin try ... except end; end` | `ERROR` |
| `begin Foo(MV_X, MV_ELL); end` | No error. Two `identifier` children of `exprArgs` |
| `begin try MV_ELL; except end; end` | No error. `statements` > `statement` > `identifier` |
| `begin MV_X := TStringList.Create; MV_ELL; MV_X.Free; end` | No error |
| `begin MV_X := TStringList.Create; MV_ELL MV_X.Free; end` (ellipsis without `;`) | `ERROR` [Measured in M1] |

Replacing `...` with identifier `__rawpaco_ell__` parses in argument and statement positions. `$...ARGS` is replaced with `__rawpaco_mvell_ARGS__`.

**(4) Ellipsis where an identifier cannot appear needs a position-specific spelling.**

| Input | Result |
|---|---|
| `type MV_T = class(MV_P) MV_ELL end;` | `ERROR` |
| `type MV_T = class(MV_P) MV_ELL: MV_ELL; end;` | No error. `declField` |
| `procedure MV_F(MV_ELL); begin MV_ELL end;` | `ERROR` |
| `procedure MV_F(MV_ELL: MV_ELL); begin MV_ELL end;` | No error. `declArg` |

In class bodies and formal parameter lists, the `name: type` form is required. The preprocessor is lexical and context-unaware. As a remedy, after the first parse, only the ellipses near an `ERROR` are swapped to the alternative spelling (`__rawpaco_ell__: __rawpaco_ell__`) and the pattern is re-parsed. This part is highly uncertain, so it is deferred to M3; M1–M2 limit ellipsis to expression, argument, and statement positions.

**(5) Convert to a pattern IR.**

The parsed tree is not kept; it is converted to our own pattern IR (node type, field name, child list, leaf text, flags for metavariable/ellipsis/deep expression) and then `ts_tree_delete`d. Three reasons: placeholder identifiers are turned back into metavariable nodes and normalized once at load time; wrappers are stripped; and `TSTree` lifetime is decoupled from rule lifetime.

`<... e ...>` is preprocessed into a call form `__rawpaco_deep__(e)` and, during IR conversion, turned into a node meaning "contains e somewhere among its sub-expressions".

### 4.3 Matcher

Recursively match the pattern IR against a target `TSNode`; on success return `(start byte, end byte, metavariable bindings)`.

**Basic rules.**

- A match requires equal node type and field name and matching child lists. In tree-sitter-pascal keywords are named nodes such as `kBegin` and `kAssign`, so comparing only named children still distinguishes operators [Measured]
- `comment` and `pp` (compiler directives) are excluded from the target's child lists. They are grammar extras and can appear even in the middle of argument lists [Measured]
- Never match subtrees containing `ERROR` or `MISSING`, except for `raise;` below

**Leaf comparison.**

- `identifier`: case-insensitive (Pascal rule). Strip a leading `&` (reserved-word escape) before comparing
- `literalString`: exact text match. Pattern `'...'` matches any string literal
- `literalNumber`: case-insensitive text comparison. `$FF` and `255` are not considered equal (no value normalization)

**Metavariables.**

- A metavariable in an `identifier` position of the pattern matches any one named node at the same position in the target. It does not match keyword nodes or extras
- Second and later occurrences of the same metavariable require a subtree **structurally equal** to the first binding. Comparison follows the leaf rules above, so whitespace, comments, and case differences are ignored
- `$_` does not bind

**Ellipsis.**

- An ellipsis in a child list matches zero or more siblings, implemented with backtracking
- Statement-sequence patterns (`A; ...; B`) match as a **subsequence** of the child list of `block` / `statements` / `blockTr`, with implicit ellipses at both ends. As noted in HANDOFF.md, `begin...end` is `block` while try/repeat bodies are a separate node type `statements`, so all three are targets
- Whether statements after a statement ellipsis are searched inside nested blocks (equivalent to opengrep's `go_deeper_stmt`) is **on by default**, matching opengrep's (probable [Unverified]) default. **Decided (#4, 2026-11-17):** to keep rule 5 in view, a positive match that was found only by descending into a nested block is reported **one severity level lower** than the rule's severity (`svError` → `svWarning`, `svWarning` → `svInfo`; `svInfo` stays `svInfo`), and its message carries a note that it matched inside a nested block. For negative operators (`pattern-not`, `pattern-not-inside`) the deeper search simply widens what is excluded, which reduces warnings. The "found by going deeper" flag must be carried on the range through boolean composition. Rules can turn the deeper search off with `options: { go_deeper_stmt: false }`
- **Statement sequences (implemented in M2, 2026-11-19, `PatMatcher.FindSequenceMatches`).** Choices made while implementing:
  - Targets are the children of every `block`, `statements` and `blockTr`. Keyword children (`begin`, `end`, …), unnamed tokens and comments are skipped. Any `pp` directive (not only conditional ones), any `ERROR` other than the bare-`raise;` shape, and any `MISSING` node **splits the list into separate segments**, and a match must lie inside one segment. This is stricter than "ellipsis does not cross conditional directives" (it also stops adjacent items from straddling `{$I file.inc}` or `{$R-}`), in the spirit of rule 5
  - Pattern items match consecutive children with implicit ellipses at both ends; at most one match is reported per starting statement. A leading explicit `...` / `$...X` starts the range at the first statement of the segment, and a trailing one extends it to the last statement of the segment (so `pattern-inside: "$X := ...; ..."` covers the rest of the block). A middle ellipsis tries the shortest span first
  - The deeper search is used only when direct matching fails, and only for the **last** non-ellipsis item (everything after it is ellipses): that item may match any statement-level node nested inside a later sibling (a `try` body, an `if` branch, a nested `begin … end`). Such a match carries the "deeper" flag. The flag survives composition as described in Section 4.4: intersection and `pattern-inside` set it if either side has it, merging identical matches clears it if any copy lacks it, and the adapter lowers the severity only when every match reported at that range has it. The note appended to the message is ` (matched inside a nested block)`
  - In the pattern lexer, a `...` or `$...X` that is alone on its line and outside parentheses and brackets gets a `;` appended, because tree-sitter-pascal cannot parse a statement-position ellipsis without one while opengrep rules for other languages normally omit it. Rule authors may still write `...;`. No `;` is added when the next token is `else` (fixed after the M2 measurement): there it would end the `if` and the pattern would not parse, and the `;` before a `case` statement's `else` is optional anyway
  - A sequence made only of ellipses is a load error, like a single ellipsis

**Pascal-specific handling.** All stem from the shape of tree-sitter-pascal trees; in opengrep this is what the Generic AST translator absorbs.

| Phenomenon | Tree shape [Measured] | Policy |
|---|---|---|
| Paren-less calls | `Foo;` is `statement` > `identifier`; `Foo();` is `statement` > `exprCall`; `X.Free;` is `statement` > `exprDot` | Patterns `Foo(...)` and `$X.Free(...)` also match the paren-less form **in statement position**. Not in expression position (`Y := Foo`), where it cannot be told apart from a variable reference. Only a call pattern with no argument list or with arguments that are all ellipses qualifies; `Foo($X)` never matches a paren-less call. Also applies in fieldless statement positions such as the `then` branch without `;` and the `case` `else` branch, since those are still `statement` nodes [Measured in M1] |
| Argument-less `raise;` | `ERROR` > `kRaise` (a grammar hole, known in HANDOFF.md) | Pattern-side `raise;` becomes a dedicated IR node matching a target "`ERROR` holding only `kRaise`". This `ERROR` shape is an exception to "never match subtrees containing errors". [Measured in M1] The `ERROR` is an extra with no field name, placed inside the statement list it belongs to (or as the sibling just before the field it belongs to, e.g. before `except:`'s `statements` or as the `then` of `if C then raise;`). It is therefore kept as an ordinary child on both sides, so its position is compared structurally. Metavariables never bind it. `raise;` followed by more statements in the same list (`except raise; Bar; end`) parses as a `raise` node whose operand is the next statement, with an `ERROR` holding only `;`; that is a real error and is not matched. A pattern `raise` without `;` is parsed by the expression wrapper as an identifier named `raise` and so matches nothing |
| Parentheses | `(A)` is `exprParens` | Treated as transparent during matching (removed from the pattern IR at compile time; skipped on the target side) |
| Empty argument list | `Foo()` has no `exprArgs` node at all [Measured in M1] | A pattern node whose children are only ellipses (e.g. the `exprArgs` of `Foo(...)`) also matches when the target has no such child, as an empty sequence, so `Foo(...)` matches `Foo()` as in opengrep |
| Statement metavariable | `statement` wraps only expression statements (calls etc.); `if`, `block`, assignments and the like sit directly in the field or list [Measured in M2] | A pattern `statement` whose only child is a metavariable (`$S;`) also matches an unwrapped statement in that position and binds it whole; a wrapped expression statement still binds its content. Found on fpc-source in M2: before the fix `then $BODY;` did not match a `begin ... end` branch |
| Conditional compilation | `{$IFDEF A} Foo; {$ELSE} Bar; {$ENDIF}` puts both branches in the same list | Statement ellipsis does not cross `pp` conditional directives |
| `with` statements | A bare identifier in the body may be a record field | No special handling in the engine. Rule authors exclude via `pattern-not-inside`. Mandatory check item for bundled rules (measured as the largest false-positive source in HANDOFF.md) |
| Macros | In `{$MACRO ON}` files identifiers can disappear via expansion | Same as above. Whether to allow a per-file exclusion condition in rule `options` is open |
| Names in implementation headers | The name in `procedure TFoo.Bar` is `genericDot`, not `exprDot` | Not unified, so declaration names are not counted as uses |

A whole-file `ts_node_has_error` gate is not adopted. Because of `raise;`, 61% of candidate files were measured to contain errors (HANDOFF.md). Only the inside of a matched range is examined.

### 4.4 Boolean Combination

Each leaf returns a set of `(range, bindings)`, and operators combine these sets — the same framework as opengrep.

| Operator | Combination |
|---|---|
| `pattern-either` | Union |
| Positive terms of `patterns` | Keep only pairs with range inclusion and compatible bindings |
| `pattern-inside` | Keep positives whose range is inside the inside-range with compatible bindings; inherit the inside side's bindings |
| `pattern-not-inside` | Same test as above; remove matches |
| `pattern-not` | Remove those with equal range and compatible bindings |
| `pattern-regex` | Regex match ranges are leaves. Named groups bind as metavariables |
| `focus-metavariable` | Replace the reported range with the range of the bound node |

"Bindings are compatible" means every metavariable appearing on both sides refers to structurally equal subtrees. A `patterns` without any positive term is a load error.

Details (in particular evaluation order with multiple `pattern-inside` in `patterns`, and combining `pattern-either` with bindings) have historical special cases in opengrep's implementation [Source-checked: comments in `Match_search_mode.ml`]. These are settled in M2 by the differential tests of Section 7.3.

**M2 boolean combination (implemented 2026-11-19, `src/Decl/Formula.pas`).** Provisional choices, to be checked against opengrep by the differential tests of Section 7.3. The parts reachable with regex leaves (intersection of positives, `pattern-not-regex`, `pattern-either`, nesting) were confirmed on 2026-11-19 (Section 7.3); `pattern-inside`, `pattern-not` and binding compatibility remain unconfirmed:

- A rule has exactly one of `pattern`, `patterns`, `pattern-either`. `pattern-not`, `pattern-inside`, `pattern-not-inside` are accepted only directly inside `patterns`; anywhere else (rule level, inside `pattern-either`) they are load errors. Each element of an operator list is an object with exactly one key. Errors name the position, e.g. `"patterns"[1]."pattern-not": ...`
- Inside `patterns` the terms are applied in this order, regardless of how they are written: positive terms (intersected in written order), then each `pattern-inside` (keeps the positives inside it and adds its bindings), then each `pattern-not-inside`, then each `pattern-not`. Negative terms therefore see bindings inherited from `pattern-inside`
- Intersecting two positive sets keeps every match of either side whose range lies inside a compatible match of the other side, with the bindings of both merged (the inner match's bindings win on a name clash, which cannot happen for compatible pairs except as equivalent nodes)
- "Compatible" compares single-node bindings structurally (as for a repeated metavariable) and range bindings (`$...X`) by exact source text
- Results are sorted by range. Matches with the same range and the same bindings are merged; the same range with different bindings is kept through evaluation (it matters for later negative terms), and the adapter reports one diagnostic per range
- **Regex operators (implemented in M2, 2026-11-19, `src/Decl/DeclRegex.pas`).** `pattern-regex` is a positive term (allowed at rule level, in `patterns` and in `pattern-either`); it matches the raw file text, including comments and strings as in opengrep, has no bindings, and never reports zero-length matches. `pattern-not-regex` (only in `patterns`) removes a positive match when either range contains the other, since text matches rarely line up with syntax boundaries. `metavariable-regex` (only in `patterns`, value `{"metavariable": "$X", "regex": "..."}`) is applied after `pattern-inside` and before the negative terms; its metavariable must be bound by another term of the same `patterns` (load error otherwise), the regex is anchored at the start of the bound text, and case handling follows #5 (Section 4.5). Regexes run with `.` not matching newlines and `^` / `$` matching at line boundaries, as in PCRE2; named groups are rejected by `RegExpr` itself, so `pattern-regex` binds no metavariables yet
- **`focus-metavariable` (implemented in M2, 2026-11-19).** Only directly inside `patterns`, at most one per `patterns`, value a single `"$X"` (opengrep's list form, which intersects ranges, is a load error until the differential tests). The metavariable must be bound by another term of the same `patterns`. It is applied after every other term, so `pattern-not` and the other filters still judge the original range. A match without that binding, or whose binding is an empty `$...X` range, is dropped because there is nothing to report

### 4.5 Metavariable Conditions

- `metavariable-regex`: apply the regex to the **source text** of the bound node. Pascal identifiers are case-insensitive, so if a rule author forgets `(?i)`, findings are missed. **Decided (#5, 2026-11-19): when the binding is a single `identifier` node, the regex ignores case by default**, a rawpaco-specific difference from opengrep. Other bindings (string literals, other expressions, `$...X` ranges) are matched case-sensitively. The regex must match from the start of the bound text (it is anchored at the start, not at the end), and a match whose metavariable is not bound is dropped
- `metavariable-pattern`: evaluate a nested formula against the bound node's subtree
- `metavariable-comparison`: M4. Only metavariables bound to integer and string literals; operations limited to comparisons, arithmetic, `and` / `or` / `not`, and `int()` / `str()` / `len()`; anything else is a load error

### 4.6 Rule Loader

The top level accepted is a `rules:` array. Per-rule keys: `id` / `message` / `severity` / `languages` / `metadata` / `paths` / `options` / `fix`, plus the operators in Section 2.7.

- `languages`: accepts `pascal`. Whether to allow aliases (`delphi`, `fpc`) is open. Rules specifying only other languages are skipped with a one-line notice on stderr
- Rules containing keys of excluded features (`mode: taint`, `pattern-sources`, `metavariable-type`, etc.) are **load errors**. Silently skipping them would produce "I added a rule but nothing is reported", which could be misread as safe
- Unknown keys are errors too
- `severity`: the current `TSeverity` has two values, `svWarning` and `svError`, and declaration order is used by `--fail-on` comparisons [Source-checked: `Diagnostics.pas`]. Map `ERROR` / `HIGH` / `CRITICAL` to `svError` and `WARNING` / `MEDIUM` to `svWarning`. There is nowhere for `INFO` / `LOW`; **Decided (#6, 2026-11-17): add `svInfo` before `svWarning`** (adding `info` to `--fail-on`). It is needed in M2 already, as the target of the one-level downgrade of nested-block matches (#4, Section 4.3)

**M1 JSON loader (implemented 2026-11-19, `src/Decl/RuleFile.pas`).** The JSON form is opengrep's YAML written as JSON: `{"rules": [{"id": ..., "message": ..., "severity": ..., "languages": [...], "pattern": ...}]}`. Choices made while implementing it:

- Accepted rule keys in M1: `id`, `message`, `severity`, `languages`, `pattern`, `metadata` (an object, otherwise ignored), `options` (`pascal_hex_dollar`, `go_deeper_stmt`, both booleans; any other option is an error). The only top-level key is `rules`
- Every other key is a load error, with three distinct messages: keys planned for later milestones (`patterns`, `pattern-either`, `pattern-regex`, `metavariable-*`, `focus-metavariable`, `paths`, `fix`, …) say "not supported yet"; excluded features (`mode`, `pattern-sources` and the other taint keys, `metavariable-type`, `join`, `extract`, …) say "out of scope"; anything else is "unknown key"
- `id` must be non-empty and use only letters, digits, `_`, `-`, `.` so that it cannot clash with the comma-separated `--only` / `--exclude` lists. Duplicate IDs are an error both within a file and against rules already loaded
- `languages` must be a non-empty array of strings; a rule without the exact string `pascal` is skipped with a notice (aliases are still open, #10)
- `severity` is case-sensitive as in opengrep. `INFO` / `LOW` were load errors in M1 rather than being mapped to `svWarning` (reporting more severely than the author intended could fail a `--fail-on=warning` build). **M2 (2026-11-19): `svInfo` added** before `svWarning`; `INFO` / `LOW` map to it, `--fail-on=info` is accepted, the text and json formats print `info`, and the github format prints `::notice` (GitHub Actions has no `info` command). Built-in rules do not use it
- A `pattern` that compiles to a statement sequence is a load error until M2, because the M1 matcher returns no matches for it and an empty result would read as "safe" (lifted in M2 once sequences are matched)
- Loading is all-or-nothing per file. Errors are reported as `<file>: rules[<i>] (id "<id>"): <reason>`
- The developer option `--dump-rules=FILE` prints the loaded rules and their pattern IR; golden tests are in `tests/decl/load/`

**How to read YAML.** Four candidates:

| Option | Description | Assessment |
|---|---|---|
| 1 | FPC's `fcl-yaml` (`fpyaml.parser` etc.) | Its presence in the freepascal.org daily (trunk) documentation was confirmed [Measured: web search]. Not in FPC 3.2.2 used by CI [Measured (M0): no such unit among the installed 3.2.2 units, only `fcl-json/json2yaml`; not listed in the 3.2.2-era FCL reference index]. There are bug reports. **Not usable for now** |
| 2 | Vendor libyaml (C, MIT) under `vendor/` and call via cdecl | Same approach as tree-sitter. Rule 1 requires checking against `yaml.h`. Risk of fighting Windows linking again |
| 3 | Write a YAML subset in FPC | Block mappings and sequences, plain and quoted scalars, `\|` and `>` block scalars, comments. Anchors, tags, complex flow forms are **explicit errors**. Estimated 500–800 lines |
| 4 | Read JSON rule files with `fpjson` | `fpjson` is already a dependency (`RawpacoConfig.pas`), so nothing new. Multi-line patterns are awkward to write |

Recommendation: **start M1 with option 4 (JSON) and add option 3 (own subset) in M3.** This separates engine validation from YAML parser work. Finding `fcl-json` in the Windows CI unit search path is already solved (HANDOFF.md).

Whichever option, FPC standard units and functions used must be confirmed in the freepascal.org documentation before implementation per CLAUDE.md rule 1. At the time of writing, only "`fcl-yaml` appears in the trunk documentation" has been confirmed.

**Regular expressions.** opengrep uses PCRE2 [Source-checked: `libs/pcre2`]. Candidates are FPC's bundled `RegExpr` unit (`TRegExpr`) or vendoring PCRE2 under `vendor/`. The former adds no C dependency but has a different dialect.

M0 results (2026-11-17). The freepascal.org FCL reference for 3.2.2 does not document `RegExpr` and the wiki was offline, so per rule 1 the unit is **not confirmed on freepascal.org**; the facts below come from the installed unit (`regexpr.ppu`, `TRegExpr.VersionMajor/Minor` = 0.987) and a probe program [Measured]:

| Construct | Result |
|---|---|
| `(?i)`, lazy `*?`, `\b`, `^` / `$`, `(?:...)`, `{n,}`, back-references `\1` | Works. Case-sensitive by default |
| Lookahead / lookbehind `(?=` `(?!` `(?<=` `(?<!`, named groups `(?P<n>` `(?<n>` `(?'n'`, atomic `(?>` | Compile error ("unrecognized modifier") |
| Possessive `a++`, Unicode property `\p{L}` | Compile error |
| POSIX class `[[:alpha:]]` | **No error, silently misparsed** (`12abc` does not match) |
| UTF-8 | Byte-oriented: `.`, `\w`, and `[é]` each match one byte, not one character |

**Decision (#8, 2026-11-17): start with `RegExpr`.** Regexes with unsupported constructs are load errors. Because some unsupported constructs (POSIX classes) do not raise a compile error, the loader runs its own pre-check for them rather than relying on `ERegExpr`. Regexes are first used in M2; whether real-world rules need lookaround is re-evaluated at the start of M2 (alternatives: vendoring a newer Pascal `TRegExpr`, or PCRE2).

### 4.7 Integration with the Existing Rule Infrastructure

- **Registration**: create one adapter implementing `IRawpacoRule` per declarative rule and `RegisterRule` it. `InterestedNodeTypes` is `root` only, and `Check` evaluates the whole file self-contained — the same approach RAWPACO-DEPR-001 took (no cross-file state in instances)
- **`--only` / `--exclude`**: `AllRuleIds` collects IDs from registered rules, so loading rule files before `SetRuleFilter` makes these work as-is. An ID duplicating a native rule is a load error
- **CLI**: add `--rules=<file or directory>` (repeatable). Following the existing layering (project-fixed settings go in the config file), whether to add `rulePaths` to `rawpaco.json` is open
  - **Implemented in M1 (2026-11-19, `src/Decl/DeclRule.pas`).** A directory argument loads the `*.json` files directly inside it, sorted with `CompareStr` so the order is the same on Windows and Linux; it does not recurse. A path that does not exist, and a directory with no `*.json`, are errors (exit code 2). A declarative rule ID that equals a built-in rule ID ignoring case is an error, since IDs that differ only in case would be confusing in `--only` and in output. Rules are registered before `--only` / `--exclude` are checked, so those options accept declarative IDs. Skipped-language notices go to stderr. `rawpaco.json` gets no key yet (#9 stays open). End-to-end golden tests are in `tests/decl/cli/`
- **Diagnostics**: `TDiagnostic` held only a start position [Source-checked]. Add an end position for SARIF regions, `focus-metavariable`, and autofix, and add a range-reporting entry point to `TLintContext`. **Done in M2 (2026-11-19):** `TDiagnostic.EndLine` / `EndColumn` and `TLintContext.ReportRange`; native rules reporting a node get the node's end. The text, github and json formats do not print the end yet, so existing output stays byte-identical; SARIF (M3) will use it
- **Messages**: replace `$X` in `message` with bound text. **Implemented in M1 (2026-11-19, `src/Decl/MsgInterp.pas`).** References use the same name rule as patterns (`$` + uppercase letters, digits, `_`, longest match), plus `$...X`. `$X` takes only a single-node binding and `$...X` only a range binding. An unbound reference, including `$_`, is left as written; the loader prints a warning for it but does not fail, because in M2 a name bound in only one `pattern-either` branch is legitimate. Whitespace and newlines in the bound text are collapsed to single spaces so a multi-line binding cannot break the one-line text and GitHub formats
- **Suppression**: the existing `// rawpaco:ignore <RuleId>` works as-is. Whether to accept `nosemgrep` comments as an alias is open
- **Output**: add `--format=sarif`. Build SARIF 2.1.0 with `fpjson`
- **TSBindings**: functions likely to be added are `ts_node_is_named` (`api.h` line 511), `ts_node_is_missing` (517), `ts_node_is_extra` (523), `ts_node_eq` (683), `ts_node_symbol` (451). Line numbers were located in the vendored header; signatures are checked when writing declarations (rule 1)
- **Native rules**: not replaced. DEFENSE-001 (empty except) and SEC-001 (SQL string concatenation) should be expressible as declarative rules, so writing the same check both ways and comparing results is used to validate the engine (Section 7)

---

## 5. Consistency with CLAUDE.md Rules

| Rule | Handling under option (d) |
|---|---|
| 1. Verifying RTL / C libraries | Preferred configuration adds no new C dependency (JSON → own YAML, `RegExpr`). New `TSBindings` functions are checked against `api.h`. `RegExpr` and `fcl-yaml` are confirmed on freepascal.org before use |
| 2. Pinning tree-sitter-pascal | The grammar is not modified; patterns go through v0.10.2 via preprocessing and wrappers. But pattern tree shapes depend on the grammar version, so updating it may silently break user rules. Add "pattern compilation golden tests" to the update checklist |
| 3. Both positive / negative | Both kinds of samples per engine feature (operators, metavariables, each ellipsis position). The same applies to bundled declarative rules |
| 4. Self-lint | Include bundled declarative rules in `make selflint` |
| 5. False-positive avoidance | All Pascal-specific handling in Section 4.3 leans to "do not match when in doubt". Rules with excluded features error out instead of being skipped |
| 6. Oxygene out of scope | `languages` is Pascal only |
| 7. Windows / Linux | Add new units to both CI builds. Test CRLF and `paths` separators on both |
| 8. Comment policy | Preprocessing substitution rules, wrapper order, and Pascal-specific handling are places where "why" comments are mandatory |

There is one tension with rule 5. A declarative rule layer moves rule quality outside the engine (to whoever writes the YAML). Native rules were added only after measuring false positives over all of fpc-source (~4,900 files); user-written rules have no such guarantee. Make bundled and user rules distinguishable in output.

---

## 6. Incremental Roadmap

Sizes are rough FPC line estimates with low precision.

| Milestone | Scope | Size estimate | Done when |
|---|---|---|---|
| **M0** Pre-checks | Confirm `RegExpr` capabilities on freepascal.org and on a real build. Decide open items from Section 10 needed before starting | Small | Decisions recorded in HANDOFF.md |
| **M1** Pattern core | Preprocessing (metavariables, hex ambiguity error, ellipsis in expression/argument/statement positions), wrappers, pattern IR, matcher (metavariable unification, child-list ellipsis, leaf comparison, paren-less calls, `raise;`). JSON rule files, single `pattern`, `--rules`, message interpolation | 1,500–2,000 lines | A DEFENSE-001 equivalent written as a declarative rule gives the same results on the existing samples |
| **M2** Combination | `patterns` / `pattern-either` / `pattern-not` / `pattern-inside` / `pattern-not-inside`, range operations, statement-sequence patterns, `pattern-regex` / `pattern-not-regex` / `metavariable-regex`, `focus-metavariable`, diagnostic end positions, `svInfo` (target of the nested-block downgrade) | 1,000–1,500 lines | Section 7.3 differential tests pass. No crashes on all of fpc-source |
| **M3** Format and coverage | YAML subset loader, `metavariable-pattern`, declaration-level patterns and position-dependent ellipsis, `<... e ...>`, `$...ARGS`, `paths`, subset of `options`, SARIF output | 1,500–2,000 lines | Rule-author documentation and compatibility list are publishable |
| **M4** Periphery | `metavariable-comparison` (limited), `fix:` / `fix-regex` and `--fix` (suggest-only by default), rule test annotations (`// ruleid:` / `// ok:`), pre-filtering for speed if needed | 1,000–1,500 lines | Several bundled rules added, false positives measured on fpc-source |
| Out of scope | Taint, join, inter-file, types, constant propagation, SCA, extract, generic mode | — | — |

Total 5,000–7,000 lines — as large as or larger than current rawpaco (~5,800 lines). Each milestone stands alone so that after M1 and M2 one can judge whether continuing is worthwhile.

---

## 7. Test Strategy

### 7.1 Engine Tests

- Under `tests/decl/<feature>/`, place a rule file, positive samples (`.pas` that must not match), and negative samples (`.pas` that must match). Follow the existing `tests/run_tests.sh` style (checking both exit code and output)
- Pattern compilation golden tests: dump the pattern IR from pattern strings and compare to expected output. Used to detect the impact of tree-sitter-pascal updates (rule 2)
- Load-error tests: unparsable patterns, ambiguous `$ABC`, unsupported keys, `patterns` without positive terms, and duplicate IDs all yield exit code 2
- Pascal-specific handling (table in Section 4.3): positive and negative samples per row
- Unit tests for parts not yet reachable from the CLI and independent of tree-sitter (e.g. the pattern preprocessor `src/Decl/PatLexer.pas`): small programs `tests/unit/Test<Unit>.lpr` that exit non-zero on failure, run by `make test` (target `unittest`) and by a dedicated step in the Windows CI job

### 7.2 Validation on Real Code

- Run on all of fpc-source and measure absence of crashes, run time, and finding counts, reusing the measurement method used for existing rules
- Write the same checks as both native and declarative rules (DEFENSE-001, DEFENSE-002, SEC-001) and compare on fpc-source. Each difference is either an engine bug or a limit of the pattern language's expressiveness; record which

**Results (M2, 2026-11-19).** `tools/measure-fpc-source.sh` runs rawpaco over all 4,894 files of fpc-source 3.2.2, 200 files per process as for the existing baselines, keeping each process's exit code. The equivalent rules are `tests/decl/equiv/defense001.json`, `defense002.json` and `sec001.json`.

- No crashes: in all three runs below every process exited with 0 or 1, and repeating the native and load runs gave byte-identical output. The native counts still match the HANDOFF.md baseline
- Run time on the owner's machine: native rules only 187.6 s; the first version of the equivalent rules (7 rules, `--only`) 175.6 s; the 28 rules of `tests/decl/cli` together (load test) 424.3 s. Fitting a line through the last two gives roughly 90 s of fixed cost plus about 12 s per declarative rule over the corpus. This is a rough estimate, but it supports doing the pre-filtering planned for M4
- DEFENSE-001: native 57, declarative 53, no declarative-only finding. The 4 native-only findings are inside regions that tree-sitter's error recovery turned into `ERROR`. Native rules still visit nodes there, but the declarative layer does not match inside errors on purpose (Section 4.3). Confirmed by bisection for `compiler/entfile.pas` (a function result type containing `{$ifdef}` breaks the parse of what follows); the other 3 files were not checked one by one
- DEFENSE-002: 4 and 4, at the same places (the declarative rule reports at the `:=` line, the native one at the `if` line). Writing the rule found two engine problems, both fixed the same day (Section 4.3): a statement metavariable such as `$BODY` in `if ... then $BODY;` did not match a `begin ... end` block, and the automatic `;` after a lone `...` was also added before `else`, so `then` / `...` / `else` on separate lines did not parse. Before the fixes this rule found 0 of the 4
- SEC-001: 190 distinct positions against the native 200 (chains like `a + b + c` put several diagnostics at the same start, so positions rather than diagnostics are compared). All 10 native-only positions are inside `ERROR` regions; checked for the 6 in `ibconnection.pp` (the function alone gives 15 matches, the whole file 0), the other 4 not one by one. There is no declarative-only position. "The other operand is not a string literal" is written as `pattern-not: "'...' + '...'"` (`'...'` matches any `literalString`, including character constants such as `#10`). A first version without it had 10 declarative-only positions, all literal + literal
- Re-measured after the fixes: the 6 equivalent rules took 156.9 s, and the load run gave the same counts as before (424.3 s → 420.0 s)

### 7.3 Differential Tests Against opengrep (Limited)

opengrep cannot run Pascal syntactic patterns, so pattern-matching compatibility cannot be compared. Only **combination semantics** can. Rules whose leaves are only `pattern-regex` (combinations of `patterns`, `pattern-either`, `pattern-not`, `pattern-inside`) are language-independent, so the same rules and `.pas` files can be run through both opengrep and rawpaco and the ranges compared.

Place this as an optional Linux CI job with opengrep pinned. Keep regexes in these tests simple so dialect differences do not leak into results. How far opengrep accepts combination operators in `languages: [regex]` rules is [Unverified] and checked first in M2.

**Implemented (M2, 2026-11-19).** opengrep is pinned at v1.33.1 (`opengrep_manylinux_x86`, 46,517,648 bytes, SHA-256 `46e8133cc490f9f50518061590ce2f6be5a08afaeda034471c0ceda4b3899808`; v2.0.0 was six days old and removed Python, so it was not chosen). It is LGPL-2.1 and only run as an external test tool, so rawpaco is unaffected (Section 3). Each case under `tests/decl/diff/<case>/` holds `rules.yml` (opengrep form, `languages: [regex]`) and `target.pas`. `tools/opengrep-diff.bb` runs the rules through opengrep as written and through rawpaco with `languages` replaced by `[pascal]` (converted to JSON), and compares the sets of `(rule id, start byte, end byte)`. rawpaco's side comes from the developer option `--match-rules=<file.json>`, which prints every reported range in bytes; the diagnostic formats do not carry end positions, and adding them to JSON would break the fpc-source byte-for-byte regression baseline. A case may list intended differences in `expected-diff.txt`, each with its reason. `make opengrep-diff OPENGREP=<path>` runs it; it is not part of `make test` because it needs the external binary.

Scope is narrower than first planned: `pattern-inside`, `pattern-not-inside` and `pattern-not` take only Pascal pattern strings in rawpaco, so they cannot have regex leaves. What is compared is `pattern-regex`, `pattern-not-regex`, `pattern-either`, nested `patterns`, and the intersection of positives. Results of the first run (5 cases, 27 rules), all matching opengrep except one intended difference:

- Regex leaves: byte offsets (including after multi-byte UTF-8), matches inside comments and strings, `^`/`$` per line, `.` not crossing newlines, non-overlapping successive matches, case-sensitive by default
- Intersection keeps a match of either side that lies inside a match of the other side, regardless of which term is written first; partial overlaps are dropped; three positives chain
- `pattern-not-regex` removes a positive when either range contains the other, keeps partial overlaps, applies regardless of where it is written in `patterns`, is scoped to its own `patterns` when nested, and several of them combine
- `pattern-either` keeps all matches of its branches, including ones contained in or partially overlapping another; the same range from two branches is reported once
- Intended difference: for a regex that can match the empty string, opengrep reports one zero-length match at offset 0; rawpaco reports none (Section 4.4 regex operators, CLAUDE.md rule 5)

Not yet in CI: a CI job would also need Babashka for the script, which is a second pinned download and left for the owner to decide.

### 7.4 CI

Build and test on both Linux and Windows (rule 7). Windows is a 32-bit build, so check that byte offsets and lengths do not trip over `LongWord` underflow (a known trap noted in a comment in `ASTWalker.pas`).

---

## 8. Summary of tree-sitter-pascal Constraints and Workarounds

| Constraint | Workaround | Remaining risk |
|---|---|---|
| Code fragments do not parse standalone | `begin ... end` and assignment wrappers (Section 4.2) | Constructs that cannot appear inside the wrappers (type expressions, standalone class members, parts of `uses`) need more wrapper kinds |
| `$X` collides with hex literals | Substitution in preprocessing; ambiguous names are errors | Incompatible with opengrep; porting rules requires renaming |
| `...` does not parse | Position-dependent placeholders | Position detection relies on trial re-parsing; many combinations slow loading |
| `raise;` becomes `ERROR` | Dedicated IR node and exception rule | If a grammar update parses it correctly, this special case must be removed |
| Paren-less calls are not call nodes | Unified only in statement position | Paren-less function calls in expression position cannot be detected (misses, not false positives) |
| `block` and `statements` are different node types | Treat both (and `blockTr`) as statement sequences | If a grammar update adds types, matches silently stop; caught by golden tests |
| Both conditional-compilation branches sit in the same tree | Statement ellipsis does not cross directives | Patterns fully inside a directive branch also match inactive branches |
| Macros and `{$I}` includes are not expanded | Not handled in the engine | Responsibility of rule authors |
| No type information or symbol table | Features depending on types and name resolution are excluded | False positives where a name's referent changes, e.g. inside `with` |

---

## 9. Risks

1. **Mismatch with the expectation of "compatibility".** The biggest risk. There is no way to compare syntactic-pattern behavior with opengrep, and Pascal-specific handling and the `$ABC` rule are deliberately incompatible. Documentation should describe it as "a Pascal dialect based on the opengrep rule format" and provide a compatibility list (supported, unsupported, behaves differently) from the start.
2. **Return on investment.** Adding code as large as rawpaco itself yields "rules can be written in YAML", with no existing Pascal rule assets. That is why there is a go/no-go checkpoint after M1–M2.
3. **Responsibility for false positives.** As noted at the end of Section 5, the quality of user rules cannot be guaranteed.
4. **Dependency on the grammar version.** User rules depend indirectly on node shapes; updating the grammar can make rules silently stop matching.
5. **Position-dependent ellipsis (Section 4.2 (4)).** Measured on only a few examples; unknown whether it generalizes to declaration-level patterns. If M3 struggles, drop declaration-level patterns or combine with option (e) queries.
6. **Regex dialect differences.** If `RegExpr` is insufficient, PCRE2 vendoring is needed, which could revive Windows linking problems.
7. **Performance.** A naive implementation is "rules × leaves × nodes" matching. Expected to be fine while bundled rules are few, but not measured.
8. **License discipline.** If implementers write code while looking at the opengrep source, it may be suspected of being a derivative. The operating rules in Section 3 must be followed.

---

## 10. Open Items (Owner Decisions Needed)

1. ~~**Overall direction**~~: **Settled (2026-11-16).** Proceed with option (d)
2. ~~**Language and location of this document**~~: **Settled (2026-11-16).** Follows the convention: this English file is canonical, the Japanese one is `_jp`
3. ~~**`$ABC`-style metavariables**~~: **Settled (2026-11-17).** Load error by default; per-rule `options: { pascal_hex_dollar: true }` treats them as hex literals with a warning (Section 4.2)
4. ~~**Default for `go_deeper_stmt`**~~: **Settled (2026-11-17).** On by default; matches found only inside nested blocks are reported one severity level lower; `options: { go_deeper_stmt: false }` turns it off (Section 4.3)
5. ~~**`metavariable-regex` on identifiers**~~: **Decided (2026-11-19).** When the binding is a single identifier node, the regex ignores case by default (a deliberate difference from opengrep). Other bindings (string literals, expressions, `$...X` ranges) stay case-sensitive (Section 4.5)
6. ~~**`severity`**~~: **Settled (2026-11-17).** Add `svInfo` (needed from M2 by #4)
7. **YAML**: JSON first + own subset, or vendor libyaml?
8. ~~**Regex**~~: **Settled (2026-11-17).** Start with `RegExpr`; unsupported constructs are load errors; re-evaluate at the start of M2 (Section 4.6)
9. **How rules are specified**: CLI `--rules` only, or also a key in `rawpaco.json`?
10. **`languages` aliases**, **accepting `nosemgrep` comments**
11. **Bundled declarative rules**: move some native rules to declarative rules, or keep only as double implementations for validation?
12. **Simple taint**: consider as a future rawpaco-specific feature? A possible basis (an own CFG and dataflow engine) is designed in [DATAFLOW_ENGINE_DESIGN.md](DATAFLOW_ENGINE_DESIGN.md), Section 11 and its open question 10; this item stays open

---

## Appendix: What Was Done in This Study

- rawpaco: read `CLAUDE.md`, `HANDOFF.md`, main units under `src/`, `Makefile`, CI configuration, `LICENSE`. `fpc` is not available in this environment, so **rawpaco itself was not built or tested**
- tree-sitter-pascal: checked parse results of about 60 code fragments with a small verification program built with gcc from `lib.c` and `parser.c` under `vendor/` (in a scratchpad, not in the repository). The [Measured] items in Sections 4.2 and 4.3 come from this
- opengrep: fetched the public repository and checked the license, the supported-language list, line counts per directory, `Rule.ml` / `Xpattern.ml` / `Xlang.ml` / `Range_with_metavars.ml`, and relevant parts of `Match_search_mode.ml` / `Generic_vs_generic.ml` / `Parse_rule.ml`. **opengrep was not built or run.** Statements about behavior come from reading the source and prior knowledge
- FPC `fcl-yaml`: confirmed by web search that it appears in the freepascal.org daily documentation. Its absence from FPC 3.2.2 and the capabilities of `RegExpr` were not checked at design time; both were checked in M0 (Section 4.6)
