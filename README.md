# rawpaco

tree-sitter-pascal を用いた、FPC/Lazarus 向け Pascal 静的解析（lint）ツール。

## 状態

初期段階（ブートストラップ）。lint ルールは未実装。

## 実装方針

- 実装言語: FPC (Object Pascal)
- 構文解析: tree-sitter-pascal（tree-sitter の C API を cdecl で直接呼び出す）
- 対象: Delphi/FPC 系 Pascal（Oxygene は対象外）

## ディレクトリ構成

- `src/` — ツール本体
- `tests/` — lint ルールごとの positive/negative サンプル

## 開発ルール

[CLAUDE.md](CLAUDE.md) を参照。

## 引き継ぎ

セッション間の引き継ぎ事項は [HANDOFF.md](HANDOFF.md) を参照。

## ライセンス

MIT License。[LICENSE](LICENSE) を参照。
