# tests

lint ルールごとのサンプルコードを配置する。CLAUDE.md のテスト方針（ルール3）に従い、ルール追加時は positive/negative 両方のサンプルを必須とする。

- `positive/` — 誤検知してはいけないコード（警告が出ないことを確認する）
- `negative/` — 検知すべきコード（警告が出ることを確認する）

配置規約: それぞれの配下にルールIDと同名のサブディレクトリを作る（例: `positive/RAWPACO-SEC-001/`, `negative/RAWPACO-SEC-001/`）。1ルールにつき複数の `.pas` サンプルを置いてよい。詳細な実行方法は `docs/RULE_ENGINE_DESIGN.md` を参照。

注意: `positive/` のサンプルは「そのルールが発火しないこと」だけでなく **全ルールについて警告ゼロ（終了コード0）であること** を要求される（`run_tests.sh` が終了コードも検証しているため）。他のルールを誤って踏まないサンプルにすること。

`RAWPACO-DEPR-002` / `RAWPACO-HALLUC-001` は `data/fpc-rtl-symbols.txt` を参照する。実行時の探索順は `src/FPCSymbols.pas` を参照（リポジトリ直下から `./src/rawpaco` を起動する通常の使い方なら自動的に見つかる）。

`suppression/` — 抑制コメント（`// rawpaco:ignore <RuleId>`）の配線を確認するためのサンプル。個別ルールの検知可否ではなく「対象行/直前行への抑制コメントで診断が消えるか」「無関係なRuleIdを書いた場合は消えないか」というルール横断の挙動を見るため、`positive`/`negative` とは別ディレクトリに置いている（RAWPACO-DEFENSE-001を検証対象ルールとして流用）。
