# プログラムフロー: src/TSBindings.pas

*This document is a Japanese translation kept for reference. The canonical, up-to-date version is [docs/flows/tsbindings_pas.md](tsbindings_pas.md) (English).*

`TSBindings.pas` はユニットであり、実行時のロジック（`implementation`部）を持ちません。すべての関数が `external`（他所でコンパイル済みのオブジェクトへの外部バインディング）であるため、ここでの「フロー」は実行時の処理順序ではなく、**コンパイル時にどの条件分岐が選択され、最終的にどうリンクされるか**というコンパイル/リンクフローになります。

```mermaid
flowchart TD
    Start(["ユニットのコンパイル開始"]) --> Target{"コンパイルターゲットは？"}

    Target -->|"{$IFDEF LINUX}"| LinuxBranch["{$linklib c}\n※-k経由の手動-lcはFPCが\nダイナミックリンカのパスを\n誤検出するため、この方式で\nlibcリンクをFPC自身に解決させる"]

    Target -->|"{$IFDEF MSWINDOWS}"| WinBranch["{$linklib mingwex}\n{$linklib mingw32}\n{$linklib gcc}\n{$linklib ucrt}\n{$linklib kernel32}\n{$linklib winpthread}\n{$linklib mingwex}（2周目）\n{$linklib mingw32}（2周目）\n{$linklib gcc}（2周目）\n※circular依存の\n古典的2周回避策"]

    LinuxBranch --> EmbedObjs
    WinBranch --> EmbedObjs

    EmbedObjs["{$L ../build/tree-sitter.o}\n{$L ../build/tree-sitter-pascal.o}\nvendorのCソースをコンパイル済み\nオブジェクトとして静的リンク"]

    EmbedObjs --> Interface["interface部:\n型定義(TSParser/PTSTree/TSLanguage/TSNode)\n+ external関数宣言"]

    Interface --> ExtFns["ts_parser_new / ts_parser_delete /\nts_parser_set_language /\nts_parser_parse_string /\nts_tree_root_node / ts_tree_delete /\nts_node_string\n（すべて実体はtree-sitter.oの中）"]

    Interface --> ExtLang["tree_sitter_pascal\n（実体はtree-sitter-pascal.oの中）"]

    ExtFns --> Consumers["呼び出し側(rawpaco.lpr等)から\ncdecl呼び出しとしてリンクされる"]
    ExtLang --> Consumers

    Consumers --> WinShim{"MSWINDOWSの場合のみ\n追加で必要なもの"}
    WinShim -->|"atexit未解決対策"| ShimNote["src/win32_atexit_shim.c を\nCI側でコンパイルし、\n-k経由でldに直接渡す\n（{$L}で埋め込むとFPC内部\nリンカがクラッシュするため\nこのファイルには含めない）"]

    Consumers --> End(["リンク完了・実行可能ファイル生成"])
```

## 補足

- このファイル自体に「実行される手続き」は存在しません。すべての関数は `cdecl; external;` （またはexternal name指定）であり、実体は `vendor/` 配下のCソースをコンパイルした `build/*.o` 側にあります。
- `{$linklib}` ディレクティブと `{$L}` ディレクティブは、いずれも実行時ではなく**リンク時**に効果を持ちます。図中で「フロー」として示しているのは、コンパイラがどのIFDEF分岐を通り、最終的にどんなリンカ引数・埋め込みオブジェクトの組み合わせに帰着するかという静的な決定過程です。
- Windows向けの `atexit` 未解決シンボル対策（`src/win32_atexit_shim.c`）は、`{$L}` でこのユニットに直接埋め込むとFPC 3.2.2のwin32ターゲット内部リンカがクラッシュするバグを踏むため、あえてこのファイルの管轄外（CI側で`-k`経由）としている点が設計上の重要な分岐点です。詳細な経緯は [HANDOFF.md](../../HANDOFF.md) を参照してください。
