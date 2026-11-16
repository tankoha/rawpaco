# progress.md — opengrep 互換 宣言的ルール層の実装進捗

このファイルは、`docs/OPENGREP_RULE_ENGINE_DESIGN.md`（英語・正）/ `docs/OPENGREP_RULE_ENGINE_DESIGN_jp.md` に基づく実装の進捗管理表です。セッションをまたいで「今どこまで進んでいて、次に何をするか」をここで引き継ぎます。

- HANDOFF.md との分担: HANDOFF.md はプロジェクト全体の引き継ぎ（決着した論点は削除）。本ファイルはこの実装プロジェクトのタスク状態と作業ログに限る。プロジェクトが完了したら要点を HANDOFF.md / 設計書に移し、本ファイルは削除する
- 設計書と食い違いが出たら、設計書（英語版）を先に直してから本ファイルを更新する

---

## 1. 体制と役割

| 役割 | 担当 | やること |
|---|---|---|
| 管制・オーケストレーション・レビュー | Opus（ローカルの Claude Code セッション） | 設計書からタスクを切り出して作業指示を書く、Qwen の成果物をレビューする、ビルド・テスト結果を確認する、本ファイルを更新する、commit / push する |
| 実装 | Qwen3.8:27B（ローカル。FPC 用 RAG と few-shot 例のプラグイン付き） | 作業指示に従ってコードとテストサンプルを書く |
| 方針判断 | オーナー | 「3. 未決事項」の判断、マイルストーン区切りでの続行可否 |

レビュー差し戻しが同じタスクで 3 回続いたら、Opus はその理由を「6. 作業ログ」に残し、タスクの分割し直しかオーナーへの相談を検討する。

## 2. セッション開始手順（ローカル）

作業は main で行う（2026-11-17 に `claude/exciting-einstein-hw4zfz` を main に取り込み済み）。

```bash
git checkout main
```

```bash
git pull
```

Qwen への依頼は `tools/qwen-gen.bb プロンプトファイル 出力ファイル`（ollama HTTP API、qwen3.8-27b-64k、`num_ctx` 65536）。思考トークンでコンテキストを使い切ると出力が途中で切れるので、このスクリプトは `done_reason` が `stop` 以外なら失敗にする。interface 部はこちらで書き、implementation 部だけを依頼する。Qwen は CLAUDE.md を読まないので、規約（自己 lint に通る書き方、コメント方針）はプロンプトに毎回書く。

続けて次を読む: `CLAUDE.md` → 本ファイル → 設計書の該当マイルストーン → `HANDOFF.md`（特に tree-sitter-pascal の既知の穴、Windows ビルドの経緯）。

作業前にベースラインが緑であることを確認する。

```bash
make && make test && make selflint
```

## 3. 未決事項（設計書 10章）

M1 着手前に決めたいもの（★）から順に並べる。決まったら「決定」欄を埋め、設計書の英語版 → 日本語版の順に反映する。

| # | 項目 | 推奨案 | 決定 | 必要になる時期 |
|---|---|---|---|---|
| 3 ★ | `$ABC` 形式（16 進数字のみ）のメタ変数 | 読み込みエラー | **決定（2026-11-17）**: 既定は読み込みエラー。ルールごとの `options: { pascal_hex_dollar: true }` で 16 進リテラル扱い＋標準エラーに警告 | M1 |
| 4 ★ | `go_deeper_stmt` の既定 | 無効（`options` で有効化） | **決定（2026-11-17）**: 既定で有効。入れ子のブロック内でだけ見つかった正の一致は重要度を一段下げて報告（注記付き）。`options: { go_deeper_stmt: false }` で無効化 | M1〜M2 |
| 8 ★ | 正規表現エンジン | `RegExpr` で開始（M0 の結果次第） | **決定（2026-11-17）**: `RegExpr` で開始。非対応構文は読み込みエラー（POSIX クラス等は自前で事前検査）。M2 着手時に再評価 | M0 で判断 |
| 5 | 識別子に対する `metavariable-regex` の大文字小文字 | 未定（推奨なし） | 未 | M2 |
| 6 | `severity` の `INFO` / `LOW` | `svInfo` を追加 | **決定（2026-11-17）**: `svInfo` を追加（#4 の一段下げ先として M2 で必要） | M2 |
| 7 | YAML | JSON 先行（M1）＋自作サブセット（M3） | 未 | M1（JSON は確定でよい） |
| 9 | ルールの指定方法 | `--rules` のみで開始 | 未 | M1 |
| 10 | `languages` の別名・`nosemgrep` | 未定 | 未 | M3 |
| 11 | 同梱する宣言的ルール | 検証用の二重実装に留める | 未 | M2 以降 |
| 12 | taint の簡易版 | ロードマップ外 | 未 | — |

決着済み: #1 方針 → 案 (d) 採用 / #2 設計書の言語 → 英語正・`_jp` 併置（いずれも 2026-11-16）

## 4. マイルストーンとタスク

状態: `[ ]` 未着手 / `[~]` 作業中 / `[x]` 完了（レビュー済み・テスト緑・push 済み）

### M0 事前確認

- [x] FPC 3.2.2 同梱 `RegExpr`（`TRegExpr`）の存在と機能範囲を freepascal.org で確認（CLAUDE.md ルール1）→ freepascal.org には記載なし（3.2.2 の FCL リファレンスに無く wiki は停止中）。未確認である旨を設計書 4.6・HANDOFF.md に明記し、実機確認で代える
- [x] 実機で確認: 先読み・後読み・名前付きグループ・`(?i)`・非貪欲・Unicode の扱い。結果を本ファイルと HANDOFF.md に記録→ v0.987。`(?i)`・非貪欲・`\b`・`(?:)`・後方参照は可。先読み・後読み・名前付きグループ・アトミック・所有的・`\p{}` は不可、`[[:alpha:]]` は黙って誤解釈、UTF-8 はバイト単位（表は設計書 4.6）
- [x] `fcl-yaml` が FPC 3.2.2 に含まれないことの確認（含まれていれば設計書 4.6 の YAML 方針を見直す）
- [x] 追加予定の TSBindings 関数（`ts_node_is_named` / `is_missing` / `is_extra` / `ts_node_eq` / `ts_node_symbol`）のシグネチャを `vendor/tree-sitter/include/tree_sitter/api.h` と照合
- [x] ★の未決事項（#3, #4, #8）をオーナーに確認して決定 → 3 件とも決定。#4 に伴い #6 も決定

### M1 パターン中核（目安 1,500〜2,000 行）

- [x] `src/Decl/` を作成し、`Makefile`（`-Fu`、`RULE_SOURCES`）と Windows CI（`.github/workflows/ci.yml` の `fpc` 呼び出し）に追加 → `-Fusrc/Decl`、自己 lint 対象、clean、単体テスト（`make unittest` / Windows CI の専用ステップ）を追加。`RULE_SOURCES` への追加は rawpaco 本体が Decl のユニットを使い始めるタスクで行う。Linux / Windows CI 緑（run 43902463083）
- [x] TSBindings に M0 で照合した関数を追加 → 5 関数を追加（Qwen）。`build/tree-sitter.o` にシンボルがあることは `nm` で確認済み。まだ呼び出し元が無いので、リンクでの確認は PatCompiler のタスクで行う
- [x] PatLexer: 文字列・コメントを読み飛ばすスキャナ。`$X` → `__rawpaco_mv_X__`、`$...X` → `__rawpaco_mvell_X__`、`...` → `__rawpaco_ell__`、16 進のみの名前はエラー → `src/Decl/PatLexer.pas`（Qwen）と単体テスト `tests/unit/TestPatLexer.lpr`（22 件、Qwen）。`pascal_hex_dollar`、`<...` の明示エラー、予約接頭辞 `__rawpaco_` のエラーも実装
- [ ] PatCompiler: ラッパー 3 段の試行（そのまま → `begin <P> end` → `begin __rawpaco_w__ := <P> end`）、パターン IR への変換、`ts_tree_delete`
- [ ] パターン IR のダンプ機能とゴールデンテスト
- [ ] PatMatcher: 名前付きの子の比較、`comment` / `pp` の除外、葉の比較規則、メタ変数の単一化、子の列の ellipsis（バックトラック）、`exprParens` の透過
- [ ] Pascal 固有: 文の位置の括弧なし呼び出し、`raise;` の専用ノード
- [ ] JSON ルールローダ（`fpjson`）。未知キー・未対応機能キーはエラー（終了コード 2）
- [ ] `IRawpacoRule` アダプタ（`InterestedNodeTypes = root`）と `--rules=<file|dir>`、ID 重複エラー、`--only` / `--exclude` との連携
- [ ] `message` の `$X` 補間
- [ ] テスト: `tests/decl/<機能>/` に positive / negative、読み込みエラーのテスト
- [ ] 完了条件: DEFENSE-001 相当を宣言的ルールで書き、既存サンプルでネイティブ版と同じ結果になる

### M2 合成（目安 1,000〜1,500 行）

- [ ] `patterns` / `pattern-either` / `pattern-not` / `pattern-inside` / `pattern-not-inside` と範囲演算・束縛の両立判定
- [ ] 文の並びのパターン（`block` / `statements` / `blockTr`、条件コンパイル指令をまたがない）。`go_deeper_stmt` は既定で有効、入れ子内だけの一致は重要度を一段下げる（#4）
- [ ] `svInfo` を `svWarning` の前に追加し、`--fail-on=info` を受け付ける（#6）
- [ ] `pattern-regex` / `pattern-not-regex` / `metavariable-regex`
- [ ] `focus-metavariable`、`TDiagnostic` への終了位置追加
- [ ] opengrep との差分テスト（regex 葉のみ、Linux CI の任意ジョブ、opengrep バージョン固定）
- [ ] fpc-source 全体でクラッシュなし・実行時間・件数の実測
- [ ] **続行判断（オーナー）**: M1〜M2 の成果を見て M3 に進むか決める

### M3 形式と範囲の拡張（目安 1,500〜2,000 行）

- [ ] YAML サブセットローダ
- [ ] `metavariable-pattern`、`<... e ...>`、`$...ARGS`
- [ ] 宣言レベルのパターンと位置依存の ellipsis（クラス本体・仮引数）
- [ ] `paths`、`options` のサブセット
- [ ] `--format=sarif`
- [ ] ルール作者向けドキュメントと互換性一覧

### M4 周辺（目安 1,000〜1,500 行）

- [ ] `metavariable-comparison`（限定版）
- [ ] `fix:` / `fix-regex` と `--fix`（既定は提案のみ）
- [ ] ルールのテスト用注釈（`// ruleid:` / `// ok:`）
- [ ] 同梱ルール数本の追加と fpc-source での誤検知実測

## 5. レビュー観点（Opus 用チェックリスト）

各タスクの完了前に確認する。

- [ ] `make && make test && make selflint` が緑（自己 lint 警告ゼロ。CLAUDE.md ルール4）
- [ ] positive / negative 両方のサンプルがある（ルール3）。positive は全ルールで警告ゼロ
- [ ] 新規の RTL / FCL 関数は freepascal.org で存在確認済み、cdecl 宣言は `api.h` と照合済み（ルール1）。確認できないものはコメントか HANDOFF.md に明記
- [ ] 迷う箇所は「一致させない」側に倒している（ルール5）
- [ ] tree-sitter-pascal の制約回避、false positive 回避の緩め実装、設計判断に「なぜ」のコメントがある。自明なコメントは無い（ルール8）
- [ ] Windows 32bit での `LongWord` アンダーフローなど、オフセット計算の罠を踏んでいない（ルール7。CI の Windows ジョブで確認）
- [ ] opengrep のソースを見ながらの移植になっていない。opengrep のテストデータを複製していない（設計書 3章）
- [ ] 設計書と実装が食い違う場合、設計書（英語 → 日本語）を更新した

## 6. 作業ログ

新しいものを上に追記する。1 エントリ: 日付 / 担当 / やったこと / 結果（テスト・CI）/ 次の一手。

- 2026-11-17 / Opus（ローカル）+ Qwen: M1 の最初の 3 タスク。PatLexer は interface を Opus、implementation を Qwen が担当。1 回目は papimela の qwen-gen.bb（`num_ctx` 16384）を使い、出力が途中で切れた。単引用符の文字定数の誤記と、開いた配列引数への `SetLength` もあった。→ interface を `TStringArray` に直し、`num_ctx` 65536 で途中切れを検出する `tools/qwen-gen.bb` を新設して再依頼。2 回目はレビューで機械的な修正を Opus が直接入れた（`Char` 引数、関数末尾の `end.`、変数名 `Out`、`(*)` の誤認、理由コメント）。単体テストで、Opus の `(*)` 修正の誤りと、テスト期待値の誤り（`$FF` は仕様上エラー）が見つかり修正。TSBindings の 5 宣言は Qwen が 1 回で正解。結果: make / make test（単体テスト 22 件含む）/ make selflint 緑。push 後の CI（run 43902463083）も Linux / Windows とも緑。次の一手: push して CI 確認 → PatCompiler（ラッパー 3 段の試行とパターン IR）の interface と作業指示

- 2026-11-17 / Opus（ローカル）: ローカル main を `claude/exciting-einstein-hw4zfz` に fast-forward。ベースライン（make / test / selflint）緑。M0 の確認 4 項目を完了。`RegExpr` 検証プログラムは Qwen（qwen3.8-27b-64k、ollama HTTP API。呼び出しは papimela の `tools/qwen-gen.bb` を `PAPIMELA_QWEN_MODEL` 指定で流用）に書かせ、レビュー 1 回で採用・実行した（リポジトリには入れていない）。続けてオーナーと協議し、★の #3・#4・#8 と、#4 に伴い #6 を決定（設計書 英→日 に反映）。push は未実施。M0 完了。次の一手: M1 の最初のタスク（`src/Decl/` 作成と TSBindings への関数追加）の作業指示を書く
- 2026-11-16 / Claude（クラウド）: 設計書を作成し、オーナーが案 (d) を採用。英語版を正とし `_jp` を併置。本ファイルを新規作成。実装は未着手。次の一手: ローカルセッションで M0 に着手
