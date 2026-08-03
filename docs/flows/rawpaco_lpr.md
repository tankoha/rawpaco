# プログラムフロー: src/rawpaco.lpr

現状の `rawpaco.lpr` は本格的なlint実行ではなく、tree-sitter-pascalが正しくリンク・動作することを確認する自己チェックプログラムです（[docs/RULE_ENGINE_DESIGN.md](../RULE_ENGINE_DESIGN.md) 1.1節で述べている通り、ルールエンジン実装時にこの内容は `LintDriver` 等へ置き換わる想定）。

```mermaid
flowchart TD
    Start(["プログラム開始"]) --> Print["バージョン文字列・ステータスを出力"]
    Print --> NewParser["Parser := ts_parser_new"]
    NewParser --> TryOuter["try（外側）"]

    TryOuter --> SetLang["ts_parser_set_language(Parser, tree_sitter_pascal)"]
    SetLang --> LangOk{"戻り値は true か？"}

    LangOk -->|"false"| Err["標準エラーに\n'language failed to load' を出力"]
    Err --> Halt1["Halt(1)\n※プロセスを即終了。\nHaltはtry/finallyの巻き戻しを\n行わないため、後続のfinally\n(ts_parser_delete)は実行されない"]
    Halt1 --> ProcessExit(["プロセス終了(exit code 1)"])

    LangOk -->|"true"| MakeSource["Source := 'program p; begin end.'"]
    MakeSource --> Parse["Tree := ts_parser_parse_string(Parser, nil, Source, Length(Source))"]
    Parse --> TryInner["try（内側）"]

    TryInner --> Root["Root := ts_tree_root_node(Tree)"]
    Root --> PrintSexp["ts_node_string(Root)の結果を\n'self-check parse: ...' として出力"]
    PrintSexp --> FinallyInner["finally（内側）\nts_tree_delete(Tree)"]
    FinallyInner --> FinallyOuter["finally（外側）\nts_parser_delete(Parser)"]
    FinallyOuter --> End(["プログラム正常終了(exit code 0)"])
```

## 補足

- 外側の `try`/`finally` は `Parser`（`ts_parser_new` で確保）の解放を、内側の `try`/`finally` は `Tree`（`ts_parser_parse_string` で確保）の解放を担当しており、tree-sitterのCライブラリ側で確保したリソースをFPC側で確実に解放する対応関係になっています。
- 言語ロード失敗時の `Halt(1)` はtry/finallyの巻き戻し（アンワインド）を経由しないため、`Parser` は解放されずにプロセスごと終了します。プロセス終了時にOSがメモリを回収するため実害はありませんが、例外による終了とは挙動が異なる点として図に明記しました。
