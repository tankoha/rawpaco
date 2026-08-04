# システムフロー図

*This document is a Japanese translation kept for reference. The canonical, up-to-date version is [docs/SYSTEM_FLOW.md](SYSTEM_FLOW.md) (English).*

[docs/RULE_ENGINE_DESIGN_jp.md](RULE_ENGINE_DESIGN_jp.md) で設計したルールエンジンについて、全体の流れをMermaid図でまとめたものです。設計の詳細・各要素の担当（Sonnet5/Opus5）は設計書側を参照してください。

現時点で `src/` 配下に実際に存在する各ソースファイル単位のプログラムフローは [docs/flows/](flows/) 配下に個別ファイルとしてまとめています。

- [docs/flows/rawpaco_lpr_jp.md](flows/rawpaco_lpr_jp.md) — `src/rawpaco.lpr`（現状は自己チェック用プログラム）
- [docs/flows/tsbindings_pas_jp.md](flows/tsbindings_pas_jp.md) — `src/TSBindings.pas`（実行時ロジックを持たないコンパイル/リンクフロー）
- [docs/flows/win32_atexit_shim_c_jp.md](flows/win32_atexit_shim_c_jp.md) — `src/win32_atexit_shim.c`（Windows専用のatexit転送シム）

`vendor/` 配下の第三者コード（tree-sitter本体・tree-sitter-pascalの生成済みパーサ）は対象外としています。

## 1. GitHub Actions統合フロー（外部から見た全体像）

rawpacoがどのようにCIへ組み込まれ、開発ループに影響するかを示します。

```mermaid
flowchart LR
    Dev["開発者/AIがコードをpush"] --> GHA["GitHub Actions起動\n(.github/workflows/ci.yml)"]
    GHA --> Build["make\nvendor Cソースをgccでコンパイル\n→ FPCでrawpacoを静的リンクビルド"]
    Build --> Run["rawpaco src/*.pas\n(selflintターゲット)"]
    Run --> Diag{"診断結果は0件か？"}
    Diag -->|"0件"| Pass["終了コード0\nビルド成功"]
    Diag -->|"1件以上"| Fail["終了コード1\ntext形式で標準出力に列挙"]
    Fail --> Fix["コード側を修正\n(true positiveとして扱う)"]
    Fix --> Dev
    Pass --> Merge["レビュー・マージ"]
```

**実装状況の注記（2026-08-04、実装済み）**: `--format=github` オプション、PRへのインライン注釈、`// rawpaco:ignore <RuleId>` による抑制コメントは、`docs/RULE_ENGINE_DESIGN.md` 4節で設計された内容がいずれも実装済み。上図のselflintターゲットは既定の `text` 形式のままだが（自ソースのlintにPR注釈形式は不要なため）、`--format=github`/`--format=json` は他の呼び出し（例: PRチェック用ワークフローへの組み込み）で利用できる。プロジェクトコード側の誤検知にも `// rawpaco:ignore <RuleId>` という逃げ道が「見つかった診断は必ず直す」という既定の運用に加わった。

## 2. rawpaco内部の実行フロー

`rawpaco.lpr`が起動してから終了コードを返すまでの、1回の実行内の流れです（設計書1.1/1.6節に対応）。

```mermaid
flowchart TD
    CLI["rawpaco.lpr\nCLIエントリポイント"] --> Driver["LintDriver"]
    Driver --> Enum["対象ファイル列挙\n(コマンドライン引数のパス)"]
    Enum --> FileLoop{"各対象ファイルについて"}

    FileLoop --> Read["ファイル読み込み(Source)"]
    Read --> Parse["ts_parser_parse_string\n(TSBindings.pas経由)"]
    Parse --> Root["ts_tree_root_node"]
    Root --> Ctx["TLintContext.Create\n(ファイル名・Sourceを保持)"]
    Ctx --> Walk["ASTWalker.WalkTree(Root, Ctx)"]

    subgraph Registry["RuleRegistry"]
        Dispatch["ノード種別 → 関心のあるルールの\nディスパッチテーブル"]
    end

    AllRules["Rules/AllRules.pas\n(usesで全ルールユニットを列挙、\ninitializationでRegisterを実行)"] -. 登録 .-> Registry

    Walk -->|"ノードごとに種別で引く"| Dispatch
    Dispatch -->|"該当ルールのCheckを呼ぶ"| RuleCheck["IRawpacoRule.Check(Node, Ctx)"]
    RuleCheck -->|"問題を検出した場合"| Report["Ctx.Report(RuleId, Message, Node)"]
    Report --> DiagList["TDiagnosticをFDiagnosticsへ蓄積"]
    DiagList --> Walk

    Walk -->|"走査完了"| Suppress["Diagnostics.IsDiagnosticSuppressed\n診断ごとに、対象行と直前行の\n// rawpaco:ignore RuleId を確認"]
    Suppress -->|"抑制されない場合"| AllDiags["全入力ファイルを通じた\n単一のAllDiagsリストへ追加\n(--format=jsonが単一配列を出すために必要)"]
    AllDiags --> FreeTree["ts_tree_deleteで解放"]
    FreeTree --> FileLoop
    FileLoop -->|"全ファイル完了"| Format{"OutFormat\n(--format由来、既定はtext)"}
    Format -->|"text"| PrintText["診断ごとにWriteLn、\nFormatDiagnosticText"]
    Format -->|"github"| PrintGithub["診断ごとにWriteLn、\nFormatDiagnosticGithub\n(GitHub Actionsワークフローコマンド)"]
    Format -->|"json"| PrintJson["1回だけWriteLn、\nFormatDiagnosticsJson\n(fcl-jsonによる単一JSON配列)"]
    PrintText --> ExitCode["終了コード決定\nAllDiagsが空かつ読み込みエラー無し→0、\nそれ以外→1"]
    PrintGithub --> ExitCode
    PrintJson --> ExitCode
```

## 3. ルール実装単位の静的関係

「1ルール=1ユニット」という実装単位が、走査・登録の仕組みとどう繋がるかを示します（設計書1.4節に対応）。

```mermaid
flowchart LR
    subgraph RuleUnit["src/Rules/RuleXxx.pas (ルール1つにつき1ユニット)"]
        Impl["TRuleXxx = class(TInterfacedObject, IRawpacoRule)\nRuleId / Description /\nInterestedNodeTypes / Check"]
        Init["initialization\nRuleRegistry.Register(TRuleXxx.Create)"]
    end

    AllRulesUnit["src/Rules/AllRules.pas\nuses RuleXxx, RuleYyy, ...;"] -->|"usesされて初めてinitializationが走る"| Init
    Init -->|"登録"| RegistryUnit["RuleRegistry.pas\nディスパッチテーブル"]
    RegistryUnit -->|"参照"| WalkerUnit["ASTWalker.pas\n(ルールのロジックは知らない)"]
