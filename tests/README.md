# tests

lint ルールごとのサンプルコードを配置する。CLAUDE.md のテスト方針に従い、ルール追加時は positive/negative 両方のサンプルを必須とする。

- `positive/` — 誤検知してはいけないコード（警告が出ないことを確認する）
- `negative/` — 検知すべきコード（警告が出ることを確認する）
