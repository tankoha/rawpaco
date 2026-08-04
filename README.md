# rawpaco

Rawpaco is a RAccoon Washing PAscal COdes.

tree-sitter-pascal を用いた、FPC/Lazarus 向け Pascal 静的解析（lint）ツール。
A static analysis (lint) tool for FPC/Lazarus Pascal, built on tree-sitter-pascal.

## 目的 / Motivation

AI（LLM）によるコード生成は便利な一方、命名規則やエラーハンドリングの一貫性のムラ、過剰な防御的コーディング、存在しないAPIの使用（hallucination）、セキュリティ考慮の漏れ、過去の学習データに引っ張られた古い書き方といった特有の問題を生みやすい傾向があります。rawpacoは、これらをGitHub Actions上でpushごとに検出することで、AIによるPascal開発の品質を継続的に高めることを目的としています。詳細な検知方針は [docs/RULE_ENGINE_DESIGN.md](docs/RULE_ENGINE_DESIGN.md) を参照。

AI-generated code tends to introduce characteristic issues — inconsistent naming and error-handling conventions across sessions, excessive defensive coding, use of nonexistent APIs (hallucination), overlooked security concerns, and outdated practices inherited from stale training data. rawpaco aims to catch these on every push via GitHub Actions, helping keep AI-assisted Pascal development consistently high quality. See [docs/RULE_ENGINE_DESIGN.md](docs/RULE_ENGINE_DESIGN.md) for the detection design.

## 開発体制 / Development Process

本ツールの設計・実装は複数のClaudeモデルが役割を分担して進めている。方針検討・設計はClaude Fable 5が担当し、実装は設計書中で担当として明記されたモデル（既定はSonnet5、複雑な設計判断を要する項目はOpus5）が行う。例えば重要度別終了コード制御（`--fail-on`）は、Fable5が方針検討・設計を行った上で実装された。機能・セクションごとの担当の内訳は [docs/RULE_ENGINE_DESIGN.md](docs/RULE_ENGINE_DESIGN.md) の「8. Owner Assignment Summary」を参照。

Design and implementation of this tool are split across multiple Claude models. Policy consideration and design are handled by Claude Fable 5, while implementation follows whichever model the design doc credits as the owner (Sonnet5 by default; Opus5 for items requiring complex design judgment calls). Severity-based exit-code control (`--fail-on`), for example, was designed by Fable5 before being implemented. See "8. Owner Assignment Summary" in [docs/RULE_ENGINE_DESIGN.md](docs/RULE_ENGINE_DESIGN.md) for the full per-item breakdown.

## 状態 / Status

lint ルールを9個実装済み（空exceptハンドラ・SQL文字列連結・シークレットのハードコード・自己矛盾する非推奨API使用・FPC RTL/FCLのdeprecatedシンボル使用・実在しないAPI(hallucination)・命名規則・生成直後の無意味なnilチェック・エラーハンドリングの不統一）。CIはLinux/Windows両方でビルド・テストし、本ツール自身のソースへの自己lintも警告ゼロを維持している。ルールごとの詳細・実装状況は [HANDOFF.md](HANDOFF.md) の「実装済みルール一覧」を参照。

9 lint rules are implemented (empty except handlers, SQL string concatenation, hardcoded secrets, self-contradictory deprecated-API use, deprecated FPC RTL/FCL symbols, hallucinated nonexistent APIs, naming conventions, redundant post-Create nil checks, and inconsistent error handling). CI builds and tests on both Linux and Windows, and self-linting (running the tool against its own source) stays at zero warnings. See the "Implemented rule list" table in [HANDOFF.md](HANDOFF.md) for per-rule details.

## 使い方 / Usage

### ビルド / Build

```sh
make
```

FPCとgcc（Cコンパイラ）が必要（動作確認はFPC 3.2.2で実施、CIも同バージョン系列を使用）。`vendor/` 配下にvendoringした tree-sitter 本体・tree-sitter-pascal を gcc で静的リンクし、`src/rawpaco`（Windowsでは `src/rawpaco.exe`）を生成する。

Requires FPC and a C compiler (gcc); verified against FPC 3.2.2, which CI also tracks. Statically links the vendored tree-sitter core and tree-sitter-pascal sources under `vendor/` via gcc, producing `src/rawpaco` (`src/rawpaco.exe` on Windows).

### 実行 / Run

```sh
./src/rawpaco [options] <file.pas> ...
```

主なオプション / Main options:

- `--config=<path>` — 設定ファイルを明示指定（省略時はカレントディレクトリから親方向へ `rawpaco.json` を自動探索）。詳細は [docs/CONFIG.md](docs/CONFIG.md)。
  Explicitly specify a config file (otherwise `rawpaco.json` is auto-discovered by searching upward from the current directory). See [docs/CONFIG.md](docs/CONFIG.md).
- `--format=text|github|json` — 出力形式（既定は `text`）。`github` は GitHub Actions のワークフローコマンド形式でPRにインライン注釈を付け、`json` は他ツール連携向けの機械可読形式。
  Output format (default `text`). `github` emits GitHub Actions workflow commands for inline PR annotations; `json` is a machine-readable array for other tooling.
- `--only=<id>[,<id>...]` / `--exclude=<id>[,<id>...]` — 有効化・無効化するルールを絞り込む（同時指定はエラー）。
  Scope which rules run (mutually exclusive; using both is an error).
- `--fail-on=error|warning` — 終了コードを1にする最低重要度（既定は`error`）。ルールはError（即対応すべき欠陥: 空exceptハンドラ・SQLインジェクション・秘密情報のハードコード・実在しないAPI参照）とWarning（いずれ直すべきだが緊急ではないもの: 非推奨API・命名規則・冗長なnilチェック・エラーハンドリングの不統一）のいずれかに分類済み。既定では診断は形式に関わらず必ず出力されるが、Warning階層はビルドを失敗させない。`--fail-on=warning`（俗称「激辛モード」）を指定すると、診断が1件でもあれば終了コードが1になる従来の挙動を再現する。
  Minimum severity that causes exit code 1 (default `error`). Every rule is classified as either Error (an actionable defect worth blocking a merge over: empty except handlers, SQL injection, hardcoded secrets, references to nonexistent APIs) or Warning (worth fixing eventually, not urgent: deprecated APIs, naming conventions, redundant nil checks, inconsistent error handling). Diagnostics are always printed regardless of format, but a Warning-tier diagnostic alone won't fail the build by default. Pass `--fail-on=warning` ("spicy mode") to restore the original behavior where any diagnostic fails the build.

個別の誤検知や意図的な例外は、対象行または直前行に `// rawpaco:ignore <RuleId>` と書くと抑制できる。

Individual false positives or deliberate exceptions can be suppressed by writing `// rawpaco:ignore <RuleId>` on the target line or the line immediately before it.

### テスト / Test

```sh
make test      # positive/negativeサンプル・CLIオプションの配線を検証 / verifies positive/negative samples and CLI option wiring
make selflint  # 本ツール自身のソースをlintし警告ゼロを確認 / lints rawpaco's own source, expecting zero warnings
```

## ディレクトリ構成 / Directory Layout

- `src/` — ツール本体 / tool source
- `src/Rules/` — lintルールごとの実装（1ルール=1ユニット） / one unit per lint rule
- `tests/` — lint ルールごとの positive/negative サンプルとCLIオプションのテスト / positive/negative samples per lint rule, plus CLI option tests
- `docs/` — 設計ドキュメント（ルールエンジン設計書など） / design documents (rule engine design, etc.)
- `data/` — `RAWPACO-DEPR-002`/`RAWPACO-HALLUC-001` が参照するFPC RTL/FCLシンボル一覧（静的コミット） / FPC RTL/FCL symbol data used by `RAWPACO-DEPR-002`/`RAWPACO-HALLUC-001` (statically committed)
- `tools/` — 上記シンボル一覧を再生成するスクリプト / scripts to regenerate the symbol data above
- `vendor/` — tree-sitter本体・tree-sitter-pascalのvendoringされたソース（バージョン固定） / vendored, version-pinned sources for tree-sitter core and tree-sitter-pascal

## 実装方針 / Design

- 実装言語: FPC (Object Pascal) / Implementation language: FPC (Object Pascal)
- 構文解析: tree-sitter-pascal（tree-sitter の C API を cdecl で直接呼び出す） / Parsing: tree-sitter-pascal (calls the tree-sitter C API directly via cdecl)
- 対象: Delphi/FPC 系 Pascal（Oxygene は対象外） / Scope: Delphi/FPC-family Pascal (Oxygene is out of scope)

## 開発ルール / Development Rules

[CLAUDE.md](CLAUDE.md) を参照。
See [CLAUDE.md](CLAUDE.md).

## 引き継ぎ / Handoff

セッション間の引き継ぎ事項は [HANDOFF.md](HANDOFF.md) を参照。
Cross-session handoff notes live in [HANDOFF.md](HANDOFF.md).

## ライセンス / License

MIT License。[LICENSE](LICENSE) を参照。
MIT License. See [LICENSE](LICENSE).
