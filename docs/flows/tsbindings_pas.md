# Program Flow: src/TSBindings.pas

*A Japanese translation is kept for reference at [docs/flows/tsbindings_pas_jp.md](tsbindings_pas_jp.md); this English version is canonical.*

`TSBindings.pas` is a unit with no runtime logic (no `implementation` body). Every function is `external` (an external binding to an object compiled elsewhere), so the "flow" here isn't a runtime processing order — it's a **compile/link flow**: which conditional branches the compiler takes at compile time, and what it ultimately links into.

```mermaid
flowchart TD
    Start(["Unit compilation starts"]) --> Target{"What's the compile target?"}

    Target -->|"{$IFDEF LINUX}"| LinuxBranch["{$linklib c}\n*A manual -lc passed via -k makes FPC\nmisdetect the dynamic linker's path,\nso this directive lets FPC itself\nresolve the libc link instead"]

    Target -->|"{$IFDEF MSWINDOWS}"| WinBranch["{$linklib mingwex}\n{$linklib mingw32}\n{$linklib gcc}\n{$linklib ucrt}\n{$linklib kernel32}\n{$linklib winpthread}\n{$linklib mingwex} (2nd pass)\n{$linklib mingw32} (2nd pass)\n{$linklib gcc} (2nd pass)\n*The classic two-pass\nworkaround for circular dependencies"]

    LinuxBranch --> EmbedObjs
    WinBranch --> EmbedObjs

    EmbedObjs["{$L ../build/tree-sitter.o}\n{$L ../build/tree-sitter-pascal.o}\nStatically link the vendor C sources\nas pre-compiled objects"]

    EmbedObjs --> Interface["interface section:\ntype definitions (TSParser/PTSTree/TSLanguage/TSNode)\n+ external function declarations"]

    Interface --> ExtFns["ts_parser_new / ts_parser_delete /\nts_parser_set_language /\nts_parser_parse_string /\nts_tree_root_node / ts_tree_delete /\nts_node_string\n(all actually defined inside tree-sitter.o)"]

    Interface --> ExtLang["tree_sitter_pascal\n(actually defined inside tree-sitter-pascal.o)"]

    ExtFns --> Consumers["Linked into callers (rawpaco.lpr etc.)\nas cdecl calls"]
    ExtLang --> Consumers

    Consumers --> WinShim{"Extra requirement,\nMSWINDOWS only"}
    WinShim -->|"workaround for unresolved atexit"| ShimNote["src/win32_atexit_shim.c is compiled\non the CI side and passed directly\nto ld via -k\n(not included here via {$L}, since\nthat crashes FPC's internal linker)"]

    Consumers --> End(["Linking complete, executable produced"])
```

## Notes

- This file itself has no "procedures that get executed." Every function is `cdecl; external;` (or has an `external name` clause); the actual bodies live in `build/*.o`, compiled from the C sources under `vendor/`.
- Both the `{$linklib}` and `{$L}` directives take effect at **link time**, not at runtime. What the "flow" in the diagram shows is the static decision process by which the compiler resolves an IFDEF branch and ends up with a particular combination of linker arguments and embedded objects.
- The workaround for Windows' unresolved `atexit` symbol (`src/win32_atexit_shim.c`) deliberately falls outside this file's jurisdiction (handled via `-k` on the CI side instead), because embedding it directly into this unit via `{$L}` triggers a crash bug in FPC 3.2.2's win32-target internal linker — an important design fork. See [HANDOFF.md](../../HANDOFF.md) for the full history.
