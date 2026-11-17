# Control-Flow Graph and Dataflow Engine: Design

- Created: 2026-11-17
- Status: design document (implementation not started; no source code was changed). Nothing here is decided until the owner answers Section 14
- Subject: rawpaco at commit `cc224b2`, tree-sitter-pascal v0.10.2 as vendored
- Language: this English version is canonical. `docs/DATAFLOW_ENGINE_DESIGN_jp.md` is the Japanese reference copy; update this file first (HANDOFF.md convention)
- Related: [RULE_ENGINE_DESIGN.md](RULE_ENGINE_DESIGN.md) Sections 0, 2.3 and 2.8 (what syntax alone cannot answer; the MEM rules), [OPENGREP_RULE_ENGINE_DESIGN.md](OPENGREP_RULE_ENGINE_DESIGN.md) Section 2.7 and open item 12 (simple taint)

This document labels the strength of each claim, as the opengrep study does:

- **[Measured]** verified in this study by actually running something (the Appendix says what)
- **[Source-checked]** verified by reading the rawpaco source or the vendored grammar
- **[Unverified]** prior knowledge or inference; must be confirmed before implementation

---

## 0. Summary

**Direction (proposed by the owner):** keep tree-sitter-pascal as the parsing base and build rawpaco's own small, explicit control-flow graph (CFG) and dataflow engine, shaped from the start so that it can later grow into inter-procedural analysis.

**Assessment: feasible, and the three-stage shape is right, with four corrections to the starting points.**

1. **The IR must be structured, not a flat instruction list.** If the IR is only a list of statements with def/use, the control structure still lives in the tree-sitter tree and the CFG builder has to read tree shapes again. The IR proposed here is a small normalized statement tree (about 15 kinds) whose leaves carry classified variable occurrences. All knowledge of tree-sitter-pascal's shapes is confined to one lowering unit. Expressions are *not* flattened to three-address code (Section 3).
2. **Two analysability levels are needed, not one.** Today's MEM rules still judge a routine that contains `with` or a `{$ifdef}` (they only give up on the variables involved). If "unanalysable" silenced the whole routine at every level, re-implementing MEM-001/002 on the new engine would lose existing true positives. So: the IR (occurrence facts) is built for almost every routine; the CFG only for routines that pass the stricter gate (Section 5).
3. **"MEM-001/002 on the CFG with the current results as the regression baseline" has to be two steps.** A flow-sensitive MEM-002 is *more precise* than today's rule, so its results will legitimately differ from the baseline in both directions. Step one is a parity port that must reproduce today's output byte for byte from IR facts (this validates the lowering). Step two is the flow-sensitive version, whose every difference from the baseline is classified and reviewed (Section 9).
4. **Three constructs found by measurement need a decision that the starting list did not have** (Section 4.3):
   - `Exit`, `Break`, `Continue` and `Halt` are not keywords in this grammar. They are ordinary identifiers, so jumps are recognised by name and can be shadowed.
   - Conditional-compilation directives are tree-sitter "extras". `{$ifdef A} X; {$else} Y; {$endif}` appears in the tree as the straight sequence `X; Y;`. A CFG built naively from that contains a path that exists in no build.
   - A bare `raise` without a following `;` (as in `raise end` or `raise else`) is parsed as `raise <expression>` with the keyword swallowed as an identifier, and the surrounding structure is wrong without any local `ERROR` node.

**Size (estimate, low precision):** 2,700–3,700 lines of Pascal for milestones F1–F5 (IR, CFG, solver, three analyses, both MEM steps), tests excluded. The owner's estimate of 1,500–3,000 lines holds for the engine alone (F1–F3: about 1,900–2,500). For scale: `src/` is 7,359 lines today [Measured], and opengrep's `src/analyzing` is 9,415 lines of OCaml plus 1,956 for its IL (as recorded in the opengrep study).

**Coverage (measured on a local FPC source tree, Section 4.4):** 90.3% of routines (134,266 of 148,646) pass the CFG gate. The largest exclusions are assembler routines (4.3%), conditional compilation inside the body (3.3%) and `with` (1.6%).

**An uncomfortable side finding:** on that tree, 58% of files have at least one syntax error somewhere, and the MEM rules skip such files entirely today. Whether to relax that gate from "per file" to "per routine" is a separate decision with its own false-positive risk (Section 13, risk 6; open question 4).

---

## 1. Goals and Non-Goals

### 1.1 Goals

- A per-routine CFG that is explicit about Pascal's abnormal control flow: `try..finally`, `try..except`, `raise`, `Exit`, `Break`, `Continue`.
- A generic monotone dataflow solver and three first analyses: reaching definitions, liveness, and object state ("definitely / maybe freed").
- Rules consume facts, not tree shapes. A rule asks "is this object live on every path to the normal exit?" and never walks `try` nodes itself.
- Silence when unsure (CLAUDE.md rule 5). A routine the engine cannot model exactly yields no flow-sensitive finding. This is a closed-world design: the lowering accepts a fixed list of node types, and anything else makes the routine unanalysable.
- A place for function summaries later. Summaries attach to the routine IR, so the inter-procedural step adds data, not a new representation.
- Stay orthogonal to the declarative rule layer (`src/Decl/`, M1 in progress). The two share only build plumbing.

### 1.2 Non-Goals

- No SSA, no three-address code, no constant propagation, no alias analysis, no points-to analysis.
- No type inference and no symbol table beyond "this name is a local of this routine". The limits of RULE_ENGINE_DESIGN.md Section 0 still apply.
- No opengrep-compatible taint mode. A rawpaco-specific simple taint may be built on this engine later; it will not be called `mode: taint` (Section 11).
- No cross-unit or whole-program analysis in the milestones planned here (Section 10 describes what would be needed).
- No modelling of compiler-inserted code (implicit `try..finally` for managed types, implicit finalization of interface references and strings).
- Not a soundness-oriented verifier. Where soundness and silence conflict, the engine chooses silence.

---

## 2. Architecture

```
tree-sitter CST (per file, existing)
   │  FlowLower   the only unit that knows tree-sitter-pascal node shapes
   ▼
routine IR      structured statement tree + classified variable occurrences + call sites
   │  FlowCfg     knows only the IR; refuses routines that fail the CFG gate
   ▼
CFG             one node per simple instruction, typed edges, two exits (normal / raise)
   │  FlowSolve   worklist solver over bit-set facts, edge-kind mask
   ▼
facts           reaching definitions, liveness, object state
   │
   ▼
native rules (MEM-001/002 first)          later: summaries, declarative-layer hook
```

Proposed units under a new `src/Flow/` (needs `-Fusrc/Flow` in the `Makefile`, entries in `RULE_SOURCES`, the `selflint` and `clean` targets, and the `fpc` invocation in Windows CI, exactly as `src/Decl/` did):

| Unit | Content | Depends on |
|---|---|---|
| `FlowIR.pas` | IR types only | TSBindings |
| `FlowLower.pas` | CST → IR, analysability reasons | FlowIR, ASTHelpers |
| `FlowCfg.pas` | IR → CFG, invariant checker | FlowIR |
| `FlowDump.pas` | IR text dump, CFG DOT dump | FlowIR, FlowCfg |
| `FlowBits.pas` | fixed-size bit set | — |
| `FlowSolve.pas` | worklist solver | FlowCfg, FlowBits |
| `FlowAnalyses.pas` | reaching definitions, liveness, object state | FlowSolve |
| `FlowCache.pas` | per-file lazy cache handed to rules | all of the above |

`FlowBits` and `FlowSolve` do not depend on tree-sitter, so they can be unit-tested the way `PatLexer` is (`tests/unit/Test<Unit>.lpr`).

---

## 3. The Routine IR

### 3.1 Why this shape

- **Structured.** The IR keeps `if`, loops, `case` and `try` as tree nodes. The CFG builder then needs no tree-sitter knowledge, and a later summary pass can also use the structure (for example "is this free inside a `finally`").
- **Statement-level.** One leaf per simple statement or condition. Pascal leaves the evaluation order of arguments unspecified [Unverified: prior knowledge of the FPC reference], so an instruction-level ordering inside one statement would claim precision that the language does not give.
- **Occurrences are classified, not just "use" and "def".** The MEM rules distinguish `L.Free` (receiver), `List.Add(L)` (argument, ownership may move), `Result := L` (value copied) and `L := ...` (definition). That classification is where today's false-positive avoidance lives, so the IR preserves it.

### 3.2 Variables

Only names that are provably local to the routine are tracked:

- parameters (`declArg`), locals (`declVars` under the `local` field), inline variables (`varDef`, `varAssignDef`), loop variables, `on E:` handler variables, and `Result`
- an assignment to the routine's own name is a definition of `Result`; any other appearance of the routine's own name is treated as an unknown call

Names are compared case-insensitively. Every other name (fields, globals, properties, unit-qualified names) is "non-local" and never tracked. In Pascal a local always shadows a field or global of the same name, so this needs no symbol table, with one exception: inside a `with` body a bare name may be a member of the `with` entity. That is the reason `with` fails the CFG gate.

A variable is flagged and then treated as unknown by every analysis when:

- it is referenced inside a nested procedure or an anonymous function (`vfCaptured`)
- its address is taken with `@` (`exprUnary` with operator `kAt` [Measured]) (`vfAddressTaken`)
- it is declared with `absolute`, or another variable is declared `absolute` over it [Source-checked: `declVar` in `grammar.js`] (`vfAbsolute`)
- an inline variable's name collides with any other variable of the routine (block scoping would be needed to tell them apart)

### 3.3 Declarations (sketch)

```pascal
type
  TVarId = Integer;                       // index into TRoutineIR.Vars; -1 = non-local
  TVarKind = (vkParam, vkLocal, vkInlineVar, vkResult, vkLoopVar, vkHandlerVar);
  TVarFlag = (vfCaptured, vfAddressTaken, vfAbsolute, vfByRefParam);
  TVarInfo = record
    NameUpper: string;
    Kind: TVarKind;
    Flags: set of TVarFlag;
    TypeText: string;                     // declared type as written; '' if not a simple typeref
    DeclNode: TSNode;
  end;

  // How a tracked variable appears in an instruction.
  TOccKind = (
    okDef,        // whole-variable assignment target:  L := ...
    okUpdate,     // read and written:  L += 1
    okReceiver,   // L.<member>  (Member holds the member name)
    okArg,        // bare argument of a call:  Foo(L)  (CallIndex, ArgIndex set)
    okNilTest,    // Assigned(L), L = nil, L <> nil
    okValue);     // any other read:  X := L, A[L], L + 1, with L do
  TOccurrence = record
    VarId: TVarId;
    Kind: TOccKind;
    Member: string;
    CallIndex, ArgIndex: Integer;
    Node: TSNode;
  end;

  TCallShape = (csPlain, csMethod, csInherited, csBareStatement, csConstructor);
  TCallSite = record
    Shape: TCallShape;
    CalleeUpper: string;                  // last identifier of the callee
    ReceiverVar: TVarId;                  // for L.Foo(...); -1 otherwise
    ArgCount: Integer;
    Node: TSNode;
  end;

  // Why an instruction may raise. Ordered from weakest to strongest evidence.
  TRaiseClass = (rcNone, rcImplicit, rcCall, rcExplicit);

  TInstrKind = (ikAssign, ikExprStmt, ikCond, ikCaseSelector,
                ikForInit, ikForTest, ikForStep, ikForDone,
                ikForInInit, ikForInNext,
                ikRaise, ikReraise, ikExit, ikBreak, ikContinue, ikNoReturn,
                ikHandlerBind, ikOpaque);
  TInstr = record
    Kind: TInstrKind;
    Node: TSNode;                         // for positions and messages
    Occs: array of TOccurrence;
    Calls: array of TCallSite;
    RaiseClass: TRaiseClass;
  end;

  TStmtKind = (skInstr, skSeq, skIf, skWhile, skRepeat, skFor, skForIn, skCase,
               skTryFinally, skTryExcept, skWith, skGoto, skLabel, skAsm);
  TStmt = class
    Kind: TStmtKind;
    InstrIndex: Integer;                  // skInstr: index into TRoutineIR.Instrs
    Children: array of TStmt;             // meaning depends on Kind (documented per kind)
    HandlerCatchesAll: Boolean;           // skTryExcept
    Node: TSNode;
  end;

  TGateReason = (grNone, grSyntaxError, grKeywordAsRaiseOperand, grUnknownNodeType,
                 grMacroFile, grAsmBody,                       // IR gate (no IR at all)
                 grWith, grGotoLabel, grAsmStatement, grConditionalDirective,
                 grIncludeDirective, grShadowedJumpName, grJumpOutsideLoop,
                 grJumpInFinally, grTooLarge);                 // CFG gate (IR exists)
  TRoutineIR = class
    Name: string;
    Node: TSNode;                         // the defProc or lambda
    Vars: array of TVarInfo;
    Instrs: array of TInstr;
    Body: TStmt;
    Nested: array of TRoutineIR;          // nested procedures and anonymous functions
    IRGate, CfgGate: TGateReason;
  end;
```

`ikOpaque` is used for statements kept in the IR only so that their occurrences are visible (for example the entity list of a `with`).

### 3.4 Raise classes

Without types, almost any Pascal statement may raise: a member access may be a property getter, arithmetic may overflow, a dereference may fault. If every such statement got an exception edge with equal weight, a rule asking "can this leak on an exception path?" would always answer yes. So each instruction records the strongest evidence that it may raise, and each analysis chooses which classes it follows:

| Class | Assigned when the instruction contains | Edge kind |
|---|---|---|
| `rcExplicit` | a `raise` statement, or a call to `Abort` | `ekRaise` |
| `rcCall` | an `exprCall`, a bare-identifier statement, a statement-level `exprDot`, `inherited`, or a `for..in` step (enumerator calls) | `ekMayRaiseCall` |
| `rcImplicit` | an `exprDot` in expression position (possible property getter), `as`, `^`, a subscript, `div` / `mod` | `ekMayRaiseImplicit` |
| `rcNone` | none of the above | no edge |

A rule that must not produce false positives follows `ekRaise` and `ekMayRaiseCall` only. A rule that needs an over-approximation of paths (for example to prove "freed on every path") follows all three.

---

## 4. From tree-sitter-pascal to the IR

### 4.1 Node shapes (all [Measured] with a dump probe on v0.10.2 unless marked)

| Construct | Tree shape | Notes for lowering |
|---|---|---|
| Routine | `defProc` with fields `header` (`declProc`), `local` (multiple: `declVars`, `declConsts`, `declLabels`, nested `defProc`), `body` (`block` or `asm`) | Method names are `genericDot`, operators `operatorName` |
| Program main block | `block` directly under `program` | Not a routine in F1–F5 (open question 12) |
| Statement list | `block` (`begin..end`) and `statements` (bodies of `try`, `repeat`); children are positional, no field names | Both must be handled (known trap, HANDOFF.md) |
| Assignment | `assignment` with `lhs`, `operator`, `rhs`; operator is `kAssign`, `kAssignAdd`, `kAssignSub`, `kAssignMul`, `kAssignDiv` | Compound operators give `okUpdate` |
| Call statement | `statement` > `exprCall` (`entity`, `args`), or `statement` > `identifier` (no parentheses), or `statement` > `exprDot` | `Foo()` has no `args` field |
| `if` | `if` with `condition`, `then`; `ifElse` with `condition`, `then`, `else` | `if X then else Y` is an `ifElse` with no `then` field. An empty branch is the anonymous token `;` in the field |
| `while` | `while` with `condition`, `body` | |
| `repeat` | `repeat` with `body` (`statements`), `condition` | |
| `for` | `for` with `start` (`assignment`), `kTo` or `kDownto`, `end`, `body` | `for var K := ...` gives `varAssignDef` as the `lhs` of `start` |
| `for..in` | `foreach` with `iterator`, `iterable`, `body` | `for var E in List do` does **not** parse: `ERROR` (grammar gap) |
| `case` | `case`; selector is the first named child (no field); arms are `caseCase` with `label` (`caseLabel`, may contain `range`) and `body`; the `else` branch has **no wrapper node**: its statements are direct children of `case` after the `kElse` token | An arm with an empty body has `;` in `body` |
| `try..finally` | `try` with field `try` (`statements`, absent when empty) and field `finally` (multiple: the `kFinally` token, then `statements`) | |
| `try..except` | `try` with field `except` (multiple): the `kExcept` token, then either `statements`, or `exceptionHandler` nodes followed by an optional `exceptionElse` | Empty `except end` has only the token |
| Handler | `exceptionHandler` with `variable` (multiple: `identifier` and `:`), `exception` (`typeref`), `body` | `exceptionElse` has no fields; statements are positional |
| `raise E` | `raise` with field `exception` | `raise E at Addr` leaves an `ERROR` inside the `raise` node |
| `raise;` | **not accepted by the grammar**: an `ERROR` node flagged extra whose only child is `kRaise`. It sits as a sibling *before* the slot it belongs to: before the `;` token in `then` / `body`, before the (empty) `statements` in an `except` section, or among the children of `statements` / `block` | Section 4.3 |
| `Exit`, `Break`, `Continue`, `Halt` | plain `identifier` in a `statement`, or `exprCall` with that identifier as `entity` (`Exit(3)`) | Not keywords (0 occurrences of `kExit` / `kBreak` / `kContinue` in `grammar.js` [Source-checked]) |
| `with` | `with` with `entity` (multiple), `body` | CFG gate |
| `goto`, labels | `goto` > `identifier`; `label` > `identifier` in statement lists; `declLabels` > `declLabel` in `local` | CFG gate |
| `asm` | `asm` > `asmBody`, as a statement or as the routine `body` | Gate |
| Inline variable | `varDef` (no initial value) as a statement; `assignment` whose `lhs` is `varAssignDef` | |
| Anonymous function | `lambda` with `args`, `type`, `local`, `body` | Becomes a nested routine |
| Nested procedure | `defProc` in the outer routine's `local` field | Becomes a nested routine |
| `inherited` | `inherited` (optional `identifier`), alone in a `statement` or as the `entity` of an `exprCall` | Call |
| Address-of, dereference | `exprUnary` with `operator` `kAt` (prefix) or `kHat` (postfix) | |
| `as` | `exprBinary` | |
| Directives | `pp`, flagged extra, at any position | Section 4.3 |

### 4.2 Lowering rules

- The lowering is a closed list. A named node type in statement position that is not in the table above sets `grUnknownNodeType` and the routine gets no IR. In expression position the lowering only needs to find identifiers, calls and the raise-class triggers, so unknown expression nodes are walked generically.
- Occurrence classification mirrors what `RuleMem001` does today [Source-checked], so the parity port (Section 9) can reproduce it exactly: declaration names and the routine header are not occurrences; the `lhs` identifier of an assignment is `okDef`; the `lhs` of an `exprDot` is `okReceiver`; the single argument of `FreeAndNil` is `okArg` like any other argument (the *rule* decides that this one is a free).
- Nested procedures and anonymous functions are lowered as separate `TRoutineIR` objects under `Nested`. Their bodies are not part of the parent's statement tree. Every parent variable they mention gets `vfCaptured`, and the mention is recorded so that the parity port still sees "freed inside a nested procedure".

### 4.3 Gates

**IR gate (no IR, no finding of any kind from this engine):**

| Reason | Condition | Why |
|---|---|---|
| `grSyntaxError` | the routine subtree contains an `ERROR` other than the bare-`raise` form, or a node flagged missing | The tree may not reflect the source |
| `grKeywordAsRaiseOperand` | a `raise` whose `exception` is an identifier spelled `end`, `else` or `until` | `raise end` / `raise else` are mis-parsed: the keyword becomes the operand and the enclosing structure is wrong, with no local `ERROR` [Measured] |
| `grUnknownNodeType` | see 4.2 | Closed-world lowering; also the tripwire for grammar updates (CLAUDE.md rule 2) |
| `grMacroFile` | the file contains `{$MACRO` | Identifiers may expand to anything; same reasoning as RAWPACO-HALLUC-001 |
| `grAsmBody` | the routine body is `asm` | Nothing to analyse |

**CFG gate (IR and occurrence facts exist; no CFG, so no flow-sensitive finding):**

| Reason | Condition | Why |
|---|---|---|
| `grWith` | a `with` statement | A bare name in the body may be a member of the entity |
| `grGotoLabel` | `goto`, `label`, or `declLabels` | Unstructured flow; too rare to be worth modelling |
| `grAsmStatement` | an `asm` statement inside a `block` | Arbitrary jumps and register effects |
| `grConditionalDirective` | a `pp` node inside the body whose text starts with `{$if`, `{$else`, `{$elseif` or `{$endif` (covers `ifdef`, `ifndef`, `ifopt`) | Both branches are in the tree as a straight sequence [Measured]; directives can also cut across statement structure |
| `grIncludeDirective` | `{$I file}` / `{$include file}` inside the body | Statements are missing from the tree |
| `grShadowedJumpName` | the routine uses `Exit`, `Break`, `Continue` or `Halt` as a statement and the same file declares something with that name | The statement may be an ordinary call |
| `grJumpOutsideLoop` | `Break` / `Continue` used as a statement outside any loop | Then it cannot be the intrinsic |
| `grJumpInFinally` | `Exit`, `Break` or `Continue` inside a `finally` block | Legality differs between compilers [Unverified]; not worth modelling |
| `grTooLarge` | CFG node count above a fixed budget (proposed: 20,000) | Bounds the effect of `finally` cloning |

**The bare `raise;` form** is accepted, because rejecting it would disable the engine for most exception-handling code (HANDOFF.md records 61% of the files relevant to RAWPACO-STYLE-002). The lowering turns an extra `ERROR` whose only child is `kRaise` into an `ikReraise` instruction placed in the slot that follows it. This is done only where the parent is `statements`, `block`, `try` (inside an `except` section), `exceptionHandler`, `exceptionElse`, `if`, `ifElse` or `caseCase`; under any other parent it is `grSyntaxError`.

**Residual risk, accepted:** a unit imported through `uses` may declare a routine named `Exit`, `Break` or `Continue`. That cannot be seen from one file.

### 4.4 How much survives the gates [Measured]

Measured with a throwaway statistics probe on a local FPC source tree (11,029 `.pas` / `.pp` files, the top-level `tests/` directory excluded). **This is not the fpc-source 3.2.2 package on which the recorded baselines were taken**; that package is not installed on the machine used for this study. The numbers show proportions, not baselines.

| Item | Routines (`defProc`) | Share |
|---|---:|---:|
| Total | 148,646 | 100% |
| Pass both gates | 134,266 | 90.3% |
| `asm` (body or statement) | 6,422 | 4.3% |
| Conditional directive in body | 4,853 | 3.3% |
| `with` | 2,416 | 1.6% |
| `ERROR` other than bare `raise` | 1,670 | 1.1% |
| Missing node | 376 | 0.3% |
| Label declaration or label | 239 | 0.2% |
| `goto` | 75 | 0.05% |
| `{$I}` in body | 68 | 0.05% |
| `raise` with keyword operand | 2 | — |

Other counts from the same run, relevant to priorities:

| Item | Routines |
|---|---:|
| Contains `try` | 8,530 |
| Uses `Exit` / `Break` / `Continue` | 17,747 |
| Contains `case` | 5,442 |
| Contains `repeat` | 1,692 |
| Contains `for..in` | 728 |
| Contains a bare `raise;` | 642 |
| Has nested procedures | 2,404 |
| Has an anonymous function | 31 |
| Has an inline variable | 105 |
| Assigns a constructor result to the same local name more than once | 884 |

The last row is the population that today's MEM rules skip because of the "exactly one creation" gate and that a flow-sensitive analysis could judge. It is an upper bound: other gates (owner argument, escape) will remove part of it.

File level: 6,416 of the 11,029 files (58%) report `ts_node_has_error` on the root; only 322 of those have nothing but bare-`raise` errors. 84,653 routines live in those files, and 75,242 of them pass both gates on their own. See risk 6.

---

## 5. The CFG

### 5.1 Data structures (sketch)

```pascal
type
  TNodeKind = (nkEntry, nkExitNormal, nkExitRaise, nkNoReturn,
               nkInstr, nkJoin, nkExceptDispatch);
  TEdgeKind = (ekSeq, ekTrue, ekFalse,
               ekCaseArm, ekCaseElse, ekCaseNoMatch,
               ekLoopBack, ekBreak, ekContinue, ekExit,
               ekRaise, ekMayRaiseCall, ekMayRaiseImplicit,
               ekHandler, ekUnhandled);
  TEdgeKinds = set of TEdgeKind;
  // Which way a finally block was entered; fcNone for nodes outside any clone.
  TCompletion = (fcNone, fcNormal, fcRaise, fcExit, fcBreak, fcContinue);

  TCfgEdge = record
    Src, Dst: Integer;
    Kind: TEdgeKind;
  end;
  TCfgNode = record
    Kind: TNodeKind;
    InstrIndex: Integer;                  // -1 for synthetic nodes
    Completion: TCompletion;
    Succ, Pred: array of Integer;         // edge indices
  end;
  TRoutineCfg = class
    IR: TRoutineIR;
    Nodes: array of TCfgNode;
    Edges: array of TCfgEdge;
    Entry, ExitNormal, ExitRaise: Integer;
  end;
```

- **One node per instruction, no basic blocks.** Routines are small, the solver does not need blocks, and golden DOT files are easier to read and to review.
- **Two exits.** `nkExitNormal` and `nkExitRaise` are separate so that "leaks on every call" and "leaks only when something raises" are different questions on the same graph. `nkNoReturn` is the sink for `Halt` and `RunError`.
- Node and edge numbers are assigned in creation order and the builder is deterministic, so a dump is stable across runs and platforms.

### 5.2 Edge rules per construct

| IR statement | Edges |
|---|---|
| `skSeq` | each child's normal end → next child (`ekSeq`) |
| `skIf` | condition → then (`ekTrue`); condition → else, or → after when there is no else (`ekFalse`); branch ends → after |
| `skWhile` | condition → body (`ekTrue`), → after (`ekFalse`); body end → condition (`ekLoopBack`). `Break` → after; `Continue` → condition |
| `skRepeat` | body → condition; condition → body start (`ekFalse`, a back edge), → after (`ekTrue`). `Continue` → condition |
| `skFor` | `ikForInit` (defines the loop variable, uses both bounds, evaluated once) → `ikForTest` → body (`ekTrue`) → `ikForStep` → `ikForTest` (`ekLoopBack`); `ikForTest` → `ikForDone` (`ekFalse`) → after. `Continue` → `ikForStep`; `Break` → after, skipping `ikForDone`. `ikForDone` makes the loop variable undefined, as the language does after normal termination [Unverified: FPC reference] |
| `skForIn` | `ikForInInit` (uses the iterable, `rcCall`) → `ikForInNext` (`rcCall`) → body (`ekTrue`, defines the iterator) → `ikForInNext` (`ekLoopBack`); `ikForInNext` → after (`ekFalse`) |
| `skCase` | selector → each arm (`ekCaseArm`); selector → else branch (`ekCaseElse`) or, when there is none, → after (`ekCaseNoMatch`) [Unverified: FPC falls through silently when no label matches]; arm ends → after |
| `ikExit` | → the exit continuation (5.3). `Exit(X)` also defines `Result` |
| `ikNoReturn` | → `nkNoReturn` |
| `ikRaise`, `ikReraise` | → the current exception target (`ekRaise`); no normal successor |
| any instruction with `RaiseClass` ≥ `rcImplicit` | one additional edge → the current exception target, of the kind in Section 3.4 |
| `skTryFinally` | Section 5.3 |
| `skTryExcept` | Section 5.4 |

"The current exception target" is the innermost of: the dispatch node of an enclosing `try..except` whose *try part* contains the instruction, the raise clone of an enclosing `finally` whose *try part* contains it, or `nkExitRaise`.

### 5.3 `try..finally`: cloned per continuation

A `finally` block runs on every way out of its `try` part: normal completion, exception, `Exit`, `Break`, `Continue`. Two designs were considered.

- **Shared:** one copy of the `finally` body with several successors. Small, but every path that enters merges with every path that leaves. A normal entry can then "leave" along the exception successor. For a may-analysis this fabricates paths, and fabricated paths become false positives.
- **Cloned (proposed):** one copy of the `finally` body per distinct *continuation*, that is, per place control goes afterwards.

The builder keeps a stack of frames (`Loop`, `Finally`, `Except`, `Routine`). A jump is resolved by walking the stack outward from the jump to its target frame. For every `Finally` frame crossed, the builder gets or creates the clone keyed by (frame, continuation node), so that two `Exit` statements in the same `try` share one clone, and all may-raise instructions in the same `try` share the raise clone.

- normal end of the try part → clone[normal] → after the statement
- may-raise instruction in the try part → clone[raise] → the exception target outside this `try`
- `Exit` → clone[exit] → next enclosing `finally`'s exit clone → … → `nkExitNormal`
- `Break` / `Continue` → clones up to the loop frame → the loop's break or continue target
- an instruction inside a clone that may raise → the exception target outside this `try`

All clones of an instruction share its `InstrIndex`, so a rule reports on instructions and reports once. Clones multiply only when a `try` is nested inside a `finally` block, which is rare; the node budget (`grTooLarge`) bounds the worst case.

### 5.4 `try..except`

- may-raise instruction in the try part → the dispatch node `nkExceptDispatch`
- dispatch → each handler (`ekHandler`). There is no type information, so which handler matches is unknown; every handler is a possible successor
- `on E: T do` starts with `ikHandlerBind`, which defines `E`
- when the `except` section is a plain statement list or has an `else` part, the handler set catches everything (`HandlerCatchesAll`). Otherwise dispatch also has an `ekUnhandled` edge to the exception target outside this `try`. `on E: Exception do` is *not* treated as catch-all: FPC can raise any object [Unverified]
- handler end → after the statement
- `ikReraise` and any may-raise instruction inside a handler → the exception target outside this `try`
- jumps out of a handler resolve through the frame stack as usual

### 5.5 Invariants (checked by a debug routine and in tests)

- every edge endpoint is a valid node; `Succ` / `Pred` agree with `Edges`
- exits and `nkNoReturn` have no successors; every other node has at least one
- every node is reachable from `nkEntry`, or is explicitly marked dead (code after `Exit`)
- an instruction with `rcNone` has no exception edge; `ikRaise` / `ikReraise` have no normal successor

---

## 6. The Dataflow Framework

### 6.1 Facts are bit sets

Every analysis planned here is a "set of things that may hold" problem. So the framework fixes the fact representation to a bit set and the join to union (or intersection, per problem). This keeps the solver non-generic, makes monotonicity easy to see, and bounds the lattice height by the bit count.

"Definitely X" is then "the set contains X and nothing else". That is how one may-analysis answers both the "definitely freed" and the "maybe freed" question.

```pascal
type
  TFlowDirection = (fdForward, fdBackward);
  TFlowJoin = (fjUnion, fjIntersection);

  TFlowProblem = class
    function Direction: TFlowDirection; virtual; abstract;
    function JoinKind: TFlowJoin; virtual; abstract;
    function BitCount: Integer; virtual; abstract;
    function EdgeMask: TEdgeKinds; virtual; abstract;        // edges this analysis follows
    procedure Boundary(var Fact: TBitSet); virtual; abstract; // at entry (forward) or exits
    procedure Transfer(NodeIndex: Integer; const InFact: TBitSet;
      var OutFact: TBitSet); virtual; abstract;
    // Optional refinement of the fact sent along one edge. Default: no change.
    procedure TransferEdge(EdgeIndex: Integer; var Fact: TBitSet); virtual;
  end;

  TFlowResult = class
    InFacts, OutFacts: array of TBitSet;
    Converged: Boolean;
  end;

function Solve(Cfg: TRoutineCfg; Problem: TFlowProblem): TFlowResult;
```

### 6.2 Solver rules

- Worklist seeded in reverse post-order (forward) or post-order (backward). `Transfer` must be monotone; that is the problem author's obligation and is stated in the unit header.
- **Exception edges carry the fact *before* the instruction.** An exception can interrupt an instruction before its effect: when `L := TFoo.Create` raises, `L` was not assigned. So along `ekRaise`, `ekMayRaiseCall` and `ekMayRaiseImplicit` a forward problem sends `InFacts[n]`, not `OutFacts[n]`. `TransferEdge` lets a problem override this for specific instructions.
- **Iteration cap.** The solver stops after `nodes × (BitCount + 1) × 4` node visits and sets `Converged := False`. A rule must treat a non-converged result as "unanalysable". With a correct monotone transfer the cap is never reached; it exists so that a bug turns into silence, not into a hang or a false positive.
- Edges outside `EdgeMask` are ignored. Nodes that become unreachable under the mask keep the initial fact.

### 6.3 First analyses

| Analysis | Direction, join | Bits | Use |
|---|---|---|---|
| Reaching definitions | forward, union | one per `okDef` / `okUpdate` occurrence, plus one "entry value" per variable | which assignment a use may see; foundation for a later simple taint |
| Liveness | backward, union | one per variable | dead stores; validates the framework in the backward direction |
| Object state | forward, union | per candidate variable: `Unassigned`, one `Live(site)` per creation site, `Freed`, `Unknown` | MEM rules; later use-after-free and double free |

Object-state transfer, per candidate variable `v`:

- creation `v := T.Create` → `{Live(site)}`
- `v := nil` → `{Unassigned}`
- `v.Free`, `v.Destroy` → `{Freed}`; `FreeAndNil(v)` → `{Unassigned}` with the free recorded
- any other definition of `v` → `{Unknown}`
- `TransferEdge` on the `ekTrue` / `ekFalse` edges of a condition that is a single `okNilTest` of `v` removes the impossible states (the `Assigned(v)` true edge drops `Unassigned`; the false edge keeps only `Unassigned`). Without this, `if Assigned(L) then L.Free` would look like a path that skips the free
- the exception edge of a free instruction carries the *post*-state. Otherwise every `L.Free` would create an "exception path on which `L` is still live"

Variables with any flag from Section 3.2, or with an `okArg` / `okValue` occurrence anywhere in the routine, are not candidates. Escape stays flow-insensitive in the first version on purpose: it keeps today's strongest false-positive gate exactly as it is.

---

## 7. How Rules Consume It

- `TLintContext` gets one lazily created `TFlowCache` per file [Source-checked: a context is created per file and freed before the tree is deleted, so `TSNode` values held by the IR stay valid]. Nothing is built unless an enabled rule asks.
- A rule keeps `InterestedNodeTypes = root` and keeps no state in its instance, as today.
- The cache hands out, per routine: the IR (or the IR gate reason), the CFG (or the CFG gate reason), and solved analyses (memoized per problem class). MEM-001 and MEM-002 then share one analysis; today each of the two rules runs the full walk separately [Source-checked].
- The contract for rule authors:
  1. A gate reason or `Converged = False` means no flow-sensitive finding for that routine.
  2. Findings are reported on instructions (`TInstr.Node`), never on CFG nodes, so `finally` clones cannot duplicate a diagnostic.
  3. A rule states in its header which edge kinds it follows and why (CLAUDE.md rule 8).
- Developer-facing CLI options, in the style of `--dump-pattern`: `--dump-flow-ir <files>` (text), `--dump-cfg <files>` (DOT, one `digraph` per routine), `--flow-stats <files>` (routine counts per gate reason, node and edge totals, solver visits). Names are open (question 11).

---

## 8. Test Strategy

- **IR golden tests** `tests/flow/ir/*.pas` + `.expected`: one small file per row of the table in 4.1, plus one per gate reason. These are the tripwire for grammar updates (CLAUDE.md rule 2) and join the update checklist next to the pattern-compilation golden tests.
- **CFG golden tests** `tests/flow/cfg/*.pas` + `.dot.expected`: text comparison of the DOT dump; Graphviz is not needed to run them. At least: every construct in 5.2, `finally` entered by each of the five completions, nested `try`, `try..finally` inside `try..except` and the reverse, bare `raise;` in each parent listed in 4.3, `Exit` inside nested loops inside `finally`.
- **Fact golden tests** `tests/flow/facts/`: dump of in/out sets per node for the three analyses.
- **Unit tests** `tests/unit/TestFlowBits.lpr`, `TestFlowSolve.lpr` (hand-built graphs, including an irreducible one and a deliberately non-monotone transfer to exercise the cap).
- **Invariant run on a corpus:** `--flow-stats` with the invariant checker enabled over all of fpc-source: no crash, no invariant violation, every solve converges; record run time with and without the engine.
- **Compiler as oracle (optional, [Unverified] how well it lines up):** for the fact golden samples, compare liveness and reaching definitions with FPC's own "does not seem to be initialized" and "assigned but never used" notes.
- **Rule samples:** every behaviour change of MEM-001/002 and every new rule needs positive and negative samples (CLAUDE.md rule 3). The cases that become checkable (several creations, reassignment, conditional creation) each get both kinds.
- **Regression on real code:** Section 9.
- **CI:** all of the above on Linux and Windows (rule 7). The Windows build is 32-bit; node and bit indices are `Integer`, and the `LongWord` loop-counter trap noted in `ASTWalker.pas` applies to every tree walk in `FlowLower`.

---

## 9. MEM-001/002 on the Engine

### Step 1: parity port (F4)

Re-express today's decision procedure over IR occurrence facts, with no CFG involved: counts of creations, frees, "protected" frees (under `skTryFinally` / `skTryExcept` handlers), frees in nested routines, and the escape flag. Keep the file-level syntax-error gate for now.

**Done when** the output is byte-identical to the current binary, in all three output formats, on `tests/`, on rawpaco's own sources, and on the baseline corpus (HANDOFF.md: fpc-source 3.2.2, 4,894 files, MEM-001 = 10, MEM-002 = 48). Use the procedure HANDOFF.md records for the `ASTHelpers` refactoring (old binary from a `git worktree`, run from the repository root so the symbol data is found).

This step proves the lowering, not the CFG. Its value is that any later difference is known to come from the flow-sensitive logic and not from a mis-read tree.

### Step 2: flow-sensitive version (F5)

For routines that pass the CFG gate, replace the counts with object-state facts:

| Rule | Flow-sensitive condition | Edge mask |
|---|---|---|
| MEM-001 | some creation site is still `Live(site)` at `nkExitNormal` on **every** normal path from that site, or is overwritten by another definition while definitely live | normal edges only |
| MEM-002 | not MEM-001, and `Live(site)` reaches `nkExitRaise` | normal edges + `ekRaise` + `ekMayRaiseCall` + `ekHandler` + `ekUnhandled` |

Routines that fail the CFG gate keep the step-1 logic.

Expected differences from the baseline, each to be confirmed by measurement:

- **New MEM-001 findings:** several creations into one variable where one is never freed; a creation overwritten while live.
- **Lost MEM-002 findings:** creation and free with no call in between (nothing can plausibly raise). These are today's least useful hits.
- **New MEM-002 findings:** a free under a `finally` that does not actually cover the code between creation and free.
- **Lost MEM-002 findings:** an exception path that a `try..except` without re-raise fully handles.

**Done when** every difference from the step-1 output on the baseline corpus is listed, classified into one of the groups above (or fixed as a bug), and every *new* finding has been read and judged a true positive. A new finding that cannot be defended is a reason to tighten the rule, not to accept it (rule 5).

"Freed on some normal paths but not on others" is deliberately **not** reported by either rule in step 2. It is a new class of finding and needs its own ID and measurement (open question 5).

---

## 10. Inter-Procedural Growth (later, not scheduled)

**Summaries** live on `TRoutineIR`: per parameter `Frees` / `Escapes` / `Defines`; per routine `MayRaise` (a raise class), `NoReturn`, `ReturnsFreshObject`; per captured variable, the same occurrence classes as in the parent.

**Call resolution without types**, in order of reliability:

1. **Nested procedure called from its parent.** Exact, because resolution is lexical. This is the first target: it removes the `vfCaptured` blanket and MEM-002's abstention when the free sits in a nested procedure.
2. **Unit-level routine, same file, name unique in the file** (no overloads, not shadowed by a local).
3. **Method of a class declared in the same file, called without a receiver from a method of the same class, not declared `virtual` / `dynamic` / `override` / `abstract`.**
4. Everything else is unknown: `X.Foo(...)` on any receiver, procedural variables, anything virtual, anything from another unit.

Summaries are computed bottom-up over the same-file call graph; a recursive cycle gets the unknown summary in the first version.

**Limits that will not go away without types:** virtual dispatch and receiver-qualified calls. A local's *declared* type text is known, which helps only for a fixed table of well-known members (`Free`, `Add`, …).

**Cross-unit:** two possible extensions, both outside the current architecture.

- The existing ppudump pipeline (`tools/gen_fpc_symbols.sh`, `tools/ppudump_symbols.awk`) could emit parameter modes (`var` / `out` / `const`) and a no-return marker for RTL and vendored units. That gives signatures, not behaviour: "frees its parameter" cannot come from a `.ppu`.
- Summaries across the project's own files would need a two-pass run (summarise all files, then lint). Today `RunLint` handles one file at a time and rules keep no cross-file state [Source-checked], so this is an architectural change (open question 9).

---

## 11. Relation to the Declarative Rule Layer

- No dependency in either direction in F1–F5. `src/Flow/` does not use `src/Decl/` and the reverse.
- A later hook, only after the opengrep layer's M2 go/no-go and after F5: a rawpaco-specific condition on a metavariable bound to a local variable, for example "definitely freed before this match" or "assigned from a match of pattern P" (via reaching definitions). The key must carry a `rawpaco-` prefix so that a rule file using it is visibly outside the opengrep-compatible subset.
- A simple intra-procedural taint (open item 12 of the opengrep design) would be that hook plus reaching definitions. It must not be named `mode: taint`. This document does not schedule it.

---

## 12. Milestones and Owners

Milestones are named F0–F7 to avoid confusion with M0–M4 (declarative layer) and P1–P13 (native rules). Owners follow the arrangement in `progress.md` (Opus: control, interfaces, review, measurement; Qwen: implementation bodies; owner: decisions), on the assumption that it also applies to this project (open question 1). Items marked **Opus** are those where the judgment is the work.

| Milestone | Scope | Size (estimate) | Owner | Done when |
|---|---|---|---|---|
| **F0** Pre-checks | Owner answers Section 14. Restore the fpc-source 3.2.2 corpus and reproduce MEM-001 = 10 / MEM-002 = 48 with the current binary. Confirm the [Unverified] language facts (for-variable after the loop, `case` without match, jumps inside `finally`) in the FPC reference | — | Owner / Opus | Decisions and reproduced baseline recorded in HANDOFF.md |
| **F1** IR | `FlowIR`, `FlowLower`, IR dump, `--dump-flow-ir`, IR golden tests, build plumbing for `src/Flow/` | 800–1,100 | Opus (interface, gate rules, bare-`raise` placement) / Qwen (implementation) | Golden tests green on Linux and Windows; no crash on the corpus; gate statistics recorded |
| **F2** CFG | `FlowCfg`, DOT dump, `--dump-cfg`, `--flow-stats`, invariant checker, CFG golden tests | 700–900 | **Opus** (`try..finally` cloning, frame stack) / Qwen (plain constructs, dump) | Golden tests green; zero invariant violations on the corpus |
| — | **Go/no-go (owner):** is the analysable share high enough on real code to continue? | | Owner | |
| **F3** Solver and analyses | `FlowBits`, `FlowSolve`, reaching definitions, liveness, fact dumps, unit tests | 400–500 | Opus (interface) / Qwen (implementation) | Fact golden tests green; every solve on the corpus converges |
| **F4** MEM parity port | Section 9 step 1; `FlowCache` | 400–500 (replaces most of the 690-line `RuleMem001.pas`) | Opus / Qwen | Byte-identical output on tests, own sources, baseline corpus |
| **F5** Flow-sensitive MEM | Section 9 step 2; object-state analysis; new samples | 400–700 | **Opus** | Classified diff against F4; every new finding judged a true positive |
| — | **Go/no-go (owner):** continue to summaries? new rule IDs? | | Owner | |
| **F6** Same-file summaries | Section 10, nested procedures first | 800–1,200 | Opus | To be defined after F5 |
| **F7** Declarative hook, simple taint | Section 11 | — | — | Not scheduled |

F1–F5 total: **2,700–3,700 lines** excluding tests. F1–F2 can run alongside declarative M1–M2: the only shared files are `Makefile`, `.github/workflows/ci.yml` and the option parsing in `rawpaco.lpr`.

---

## 13. Risks

1. **Jumps are recognised by name.** `Exit`, `Break`, `Continue`, `Halt` are identifiers. Same-file shadowing is gated; shadowing from another unit is not detectable.
2. **The definition of "may raise" decides MEM-002's precision.** Too narrow loses real leaks; too wide reports every unprotected free. The raise classes make this a per-rule choice, but the choice still has to be tuned by measurement.
3. **Conditional compilation is invisible as structure.** The gate handles directives inside a routine body. A directive *around* whole routines can still produce two `defProc` nodes for one routine; each is analysed alone, which is harmless for intra-procedural rules but matters for same-file summaries (F6).
4. **`finally` cloning can multiply nodes** for `try` nested inside `finally`. Bounded by the node budget; the budget's value is a guess until F2 measures real sizes.
5. **No types.** A property setter is a call; a `var` / `out` argument is a definition the engine cannot see (every bare argument is therefore treated as escape); operators may be overloaded. The design answers all of these with "not a candidate", which costs findings, not correctness.
6. **The syntax-error gate.** Today MEM-001/002 skip any file with a syntax error anywhere, which on the measured tree is 58% of files. A per-routine gate would roughly double coverage (63,993 routines in clean files → 134,266 passing routines). But tree-sitter's error recovery can distort the tree outside the `ERROR` node, and the `raise end` case shows a mis-parse with no local marker at all. Relaxing the gate is therefore its own measured step after F5, not part of the port.
7. **Return on investment.** F1–F5 add 35–50% to the size of `src/`, and the first visible result is two rules that already exist, made somewhat more precise. The engine pays off only if more flow-sensitive rules follow (use-after-free, double free, partial-path leaks, simple taint). Hence two go/no-go points.
8. **Subtle graph code written by a small local model.** The `try..finally` builder and the object-state transfer are easy to get almost right. They are assigned to Opus, and the invariant checker plus golden tests exist to catch the rest.
9. **Grammar pinning.** A grammar update can change shapes silently. The closed-world lowering turns unknown shapes into `grUnknownNodeType` (silence), and the IR golden tests show what changed.
10. **Performance.** Not measured. Parsing dominates today (the statistics probe needed about 78 s for 11,029 files, single-threaded, parse and one walk). CFG construction is linear in routine size and the facts are small; the cache builds nothing unless a flow rule is enabled.

---

## 14. Open Questions for the Owner

1. **Go-ahead, timing and team.** Start F0–F2 now alongside declarative M1–M2, or after the M2 go/no-go? Does the Opus + Qwen arrangement of `progress.md` apply?
2. **Progress tracking.** `progress.md` is scoped to the declarative layer. Add a section there, or a separate file for this project?
3. **Baseline corpus.** fpc-source 3.2.2 is not installed on the machine used for this study, so the recorded 10 / 48 could not be reproduced here. Reinstall it, and should the baseline output be kept somewhere (outside the repository) for diffing?
4. **Syntax-error gate.** Keep per file, or plan the per-routine relaxation as a measured step after F5 (risk 6)?
5. **New finding classes and IDs.** Partial-path leak (freed on some normal paths only), use after free, double free: new IDs (`RAWPACO-MEM-003`…) and which severity? Or none of these for now?
6. **MEM-002 may change meaning.** Step 2 drops hits where nothing between creation and free can plausibly raise, and adds hits where a `finally` does not cover the creation. The recorded 48 will change, with a classified diff. Acceptable?
7. **`with`.** Proposed: CFG gate (1.6% of routines). Alternative for later: build the CFG and treat every local mentioned inside a `with` body as unknown.
8. **Conditional compilation inside a body.** Proposed: CFG gate (3.3% of routines, likely less in application code than in the RTL). Alternative for later: model well-nested `{$if}…{$else}…{$endif}` at statement-list level as a nondeterministic branch.
9. **Cross-file summaries.** Is a two-pass whole-run mode acceptable in principle, or should rawpaco stay strictly per-file?
10. **Simple taint (opengrep design, item 12).** Record it as "possible later via this engine, under a `rawpaco-` key", or leave it fully open?
11. **Developer CLI options.** Names (`--dump-flow-ir`, `--dump-cfg`, `--flow-stats`), and should users be able to see why a routine was skipped?
12. **Scope of "routine".** Only `defProc` and anonymous functions in F1–F5 (proposed), or also the program main block and `initialization` / `finalization` sections?
13. **`finally` strategy.** Cloning per continuation (proposed) or one shared copy?

---

## Appendix: What Was Done in This Study

- Read `CLAUDE.md`, `HANDOFF.md`, `progress.md`, both existing design documents, `src/Rules/RuleMem001.pas`, `src/ASTWalker.pas`, `src/ASTHelpers.pas`, the interfaces under `src/Decl/`, `src/LintDriver.pas`, `src/Diagnostics.pas`, the `Makefile`, and the statement rules of `vendor/tree-sitter-pascal/grammar.js`.
- Built a throwaway tree-dump program (FPC, linked against the already built `build/*.o`, kept in a scratch directory outside the repository) and parsed five small sample files covering every row of the table in 4.1. Note for later probes: with absolute paths in `{$L}`, a probe does not have to live under `src/`.
- Built a second throwaway program that walks every `defProc` of a corpus and counts constructs and gate reasons; ran it on a local FPC source tree (11,029 files). Section 4.4 comes from this run.
- Ran the current `src/rawpaco` with `--only=RAWPACO-MEM-001,RAWPACO-MEM-002` on the same tree as a smoke check: 12 and 41 findings. These are **not** comparable with the recorded baseline (different tree).
- Not done: no change under `src/` or `tests/`; rawpaco was not rebuilt; nothing here was checked against the FPC reference (the [Unverified] items); opengrep was not consulted beyond the sizes already recorded in the opengrep study.
