# rawpaco

Rawpaco is a RAccoon Washing PAscal COde.

tree-sitter-pascal を用いた、FPC/Lazarus 向け Pascal 静的解析（lint）ツール。
A static analysis (lint) tool for FPC/Lazarus Pascal, built on tree-sitter-pascal.

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

## 開発ルール / Development Rules

[CLAUDE.md](CLAUDE.md) を参照。
See [CLAUDE.md](CLAUDE.md).

## 引き継ぎ / Handoff

セッション間の引き継ぎ事項は [HANDOFF.md](HANDOFF.md) を参照。
Cross-session handoff notes live in [HANDOFF.md](HANDOFF.md).

## ライセンス / License

MIT License。[LICENSE](LICENSE) を参照。
MIT License. See [LICENSE](LICENSE).
