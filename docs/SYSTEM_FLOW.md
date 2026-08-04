# System Flow Diagrams

*A Japanese translation is kept for reference at [docs/SYSTEM_FLOW_jp.md](SYSTEM_FLOW_jp.md); this English version is canonical.*

This summarizes, as Mermaid diagrams, the overall flow of the rule engine designed in [docs/RULE_ENGINE_DESIGN.md](RULE_ENGINE_DESIGN.md). See the design doc for details and per-element ownership (Sonnet5/Opus5).

The program flow for each source file that actually exists under `src/` at this point in time is documented as individual files under [docs/flows/](flows/).

- [docs/flows/rawpaco_lpr.md](flows/rawpaco_lpr.md) — `src/rawpaco.lpr` (the CLI entry point)
- [docs/flows/tsbindings_pas.md](flows/tsbindings_pas.md) — `src/TSBindings.pas` (a compile/link flow with no runtime logic)
- [docs/flows/win32_atexit_shim_c.md](flows/win32_atexit_shim_c.md) — `src/win32_atexit_shim.c` (a Windows-only `atexit` forwarding shim)

Third-party code under `vendor/` (tree-sitter itself and the generated tree-sitter-pascal parser) is out of scope here.

## 1. GitHub Actions Integration Flow (the external, big-picture view)

Shows how rawpaco is wired into CI and how it affects the development loop.

```mermaid
flowchart LR
    Dev["Developer/AI pushes code"] --> GHA["GitHub Actions triggers\n(.github/workflows/ci.yml)"]
    GHA --> Build["make\ncompile vendor C sources with gcc\n→ statically link-build rawpaco with FPC"]
    Build --> Run["rawpaco src/*.pas\n(the selflint target)"]
    Run --> Diag{"Zero diagnostics?"}
    Diag -->|"zero"| Pass["Exit code 0\nbuild succeeds"]
    Diag -->|"one or more"| Fail["Exit code 1\nlisted to stdout in text format"]
    Fail --> Fix["Fix the code\n(treated as a true positive)"]
    Fix --> Dev
    Pass --> Merge["Review and merge"]
```

**Implementation status note (2026-08-04, implemented)**: the `--format=github` option, inline PR annotations, and suppression comments via `// rawpaco:ignore <RuleId>` designed in `docs/RULE_ENGINE_DESIGN.md` section 4 are all implemented. The self-lint target above still uses the default `text` format (CI doesn't need PR-annotation output for its own source), but `--format=github`/`--format=json` are available for other invocations (e.g. wiring rawpaco into a PR-checking workflow step). A false positive in project code now has an escape hatch via `// rawpaco:ignore <RuleId>`, on top of the "any diagnostic found must be fixed" default.

## 2. rawpaco's Internal Execution Flow

The flow within a single run, from `rawpaco.lpr` starting up to it returning an exit code (corresponds to design doc sections 1.1/1.6).

```mermaid
flowchart TD
    CLI["rawpaco.lpr\nCLI entry point"] --> Driver["LintDriver"]
    Driver --> Enum["Enumerate target files\n(paths from command-line arguments)"]
    Enum --> FileLoop{"For each target file"}

    FileLoop --> Read["Read the file (Source)"]
    Read --> Parse["ts_parser_parse_string\n(via TSBindings.pas)"]
    Parse --> Root["ts_tree_root_node"]
    Root --> Ctx["TLintContext.Create\n(holds file name + Source)"]
    Ctx --> Walk["ASTWalker.WalkTree(Root, Ctx)"]

    subgraph Registry["RuleRegistry"]
        Dispatch["Node type → dispatch table of\ninterested rules"]
    end

    AllRules["Rules/AllRules.pas\n(lists every rule unit in its uses clause,\nruns Register from initialization)"] -. registers .-> Registry

    Walk -->|"looked up by type, per node"| Dispatch
    Dispatch -->|"calls the matching rule's Check"| RuleCheck["IRawpacoRule.Check(Node, Ctx)"]
    RuleCheck -->|"when a problem is found"| Report["Ctx.Report(RuleId, Message, Node)"]
    Report --> DiagList["Accumulates a TDiagnostic into FDiagnostics"]
    DiagList --> Walk

    Walk -->|"traversal complete"| Suppress["Diagnostics.IsDiagnosticSuppressed\nper-diagnostic, checking the target line\nand the line before it for\n// rawpaco:ignore RuleId"]
    Suppress -->|"not suppressed"| AllDiags["Appended to a single AllDiags list\nspanning every input file\n(needed so --format=json can emit one array)"]
    AllDiags --> FreeTree["Freed via ts_tree_delete"]
    FreeTree --> FileLoop
    FileLoop -->|"all files done"| Format{"OutFormat\n(from --format, default text)"}
    Format -->|"text"| PrintText["WriteLn per diagnostic,\nFormatDiagnosticText"]
    Format -->|"github"| PrintGithub["WriteLn per diagnostic,\nFormatDiagnosticGithub\n(GitHub Actions workflow command)"]
    Format -->|"json"| PrintJson["WriteLn once,\nFormatDiagnosticsJson\n(single JSON array via fpjson)"]
    PrintText --> ExitCode["Decide exit code\n0 if AllDiags is empty and no read errors,\n1 otherwise"]
    PrintGithub --> ExitCode
    PrintJson --> ExitCode
```

## 3. Static Relationship Between Rule Implementation Units

Shows how the "one rule = one unit" implementation model connects to the traversal/registration machinery (corresponds to design doc section 1.4).

```mermaid
flowchart LR
    subgraph RuleUnit["src/Rules/RuleXxx.pas (one unit per rule)"]
        Impl["TRuleXxx = class(TInterfacedObject, IRawpacoRule)\nRuleId / Description /\nInterestedNodeTypes / Check"]
        Init["initialization\nRuleRegistry.Register(TRuleXxx.Create)"]
    end

    AllRulesUnit["src/Rules/AllRules.pas\nuses RuleXxx, RuleYyy, ...;"] -->|"initialization only runs once it's uses'd"| Init
    Init -->|"registers"| RegistryUnit["RuleRegistry.pas\ndispatch table"]
    RegistryUnit -->|"referenced by"| WalkerUnit["ASTWalker.pas\n(knows nothing about rule logic)"]
```
