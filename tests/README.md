# tests

lint ルールごとのサンプルコードを配置する。CLAUDE.md のテスト方針（ルール3）に従い、ルール追加時は positive/negative 両方のサンプルを必須とする。

- `positive/` — 誤検知してはいけないコード（警告が出ないことを確認する）
- `negative/` — 検知すべきコード（警告が出ることを確認する）

配置規約: それぞれの配下にルールIDと同名のサブディレクトリを作る（例: `positive/RAWPACO-SEC-001/`, `negative/RAWPACO-SEC-001/`）。1ルールにつき複数の `.pas` サンプルを置いてよい。詳細な実行方法は `docs/RULE_ENGINE_DESIGN.md` を参照。
