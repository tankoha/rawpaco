# rawpaco

Rawpaco is a RAccoon Washing PAscal COdes.

tree-sitter-pascal を用いた、FPC/Lazarus 向け Pascal 静的解析（lint）ツール。
A static analysis (lint) tool for FPC/Lazarus Pascal, built on tree-sitter-pascal.

## 目的 / Motivation

AI（LLM）によるコード生成は便利な一方、命名規則やエラーハンドリングの一貫性のムラ、過剰な防御的コーディング、存在しないAPIの使用（hallucination）、セキュリティ考慮の漏れ、過去の学習データに引っ張られた古い書き方といった特有の問題を生みやすい傾向があります。rawpacoは、これらをGitHub Actions上でpushごとに検出することで、AIによるPascal開発の品質を継続的に高めることを目的としています。詳細な検知方針は [docs/RULE_ENGINE_DESIGN.md](docs/RULE_ENGINE_DESIGN.md) を参照。

AI-generated code tends to introduce characteristic issues — inconsistent naming and error-handling conventions across sessions, excessive defensive coding, use of nonexistent APIs (hallucination), overlooked security concerns, and outdated practices inherited from stale training data. rawpaco aims to catch these on every push via GitHub Actions, helping keep AI-assisted Pascal development consistently high quality. See [docs/RULE_ENGINE_DESIGN.md](docs/RULE_ENGINE_DESIGN.md) for the detection design.

## 状態 / Status

初期段階（ブートストラップ）。lint ルールは未実装。
Early bootstrap stage. No lint rules implemented yet.

## 実装方針 / Design

- 実装言語: FPC (Object Pascal) / Implementation language: FPC (Object Pascal)
- 構文解析: tree-sitter-pascal（tree-sitter の C API を cdecl で直接呼び出す） / Parsing: tree-sitter-pascal (calls the tree-sitter C API directly via cdecl)
- 対象: Delphi/FPC 系 Pascal（Oxygene は対象外） / Scope: Delphi/FPC-family Pascal (Oxygene is out of scope)

## ディレクトリ構成 / Directory Layout

- `src/` — ツール本体 / tool source
- `tests/` — lint ルールごとの positive/negative サンプル / positive/negative samples per lint rule
- `docs/` — 設計ドキュメント（ルールエンジン設計書など） / design documents (rule engine design, etc.)

## 開発ルール / Development Rules

[CLAUDE.md](CLAUDE.md) を参照。
See [CLAUDE.md](CLAUDE.md).

## 引き継ぎ / Handoff

セッション間の引き継ぎ事項は [HANDOFF.md](HANDOFF.md) を参照。
Cross-session handoff notes live in [HANDOFF.md](HANDOFF.md).

## ライセンス / License

MIT License。[LICENSE](LICENSE) を参照。
MIT License. See [LICENSE](LICENSE).
