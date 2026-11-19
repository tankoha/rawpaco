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
| 5 | 識別子に対する `metavariable-regex` の大文字小文字 | 未定（推奨なし） | **決定（2026-11-19）**: 束縛が識別子 1 個のときは既定で大文字小文字を無視する（opengrep との違い）。それ以外の束縛（文字列リテラル、式、`$...X` の範囲）は区別する | M2 |
| 6 | `severity` の `INFO` / `LOW` | `svInfo` を追加 | **決定（2026-11-17）**: `svInfo` を追加（#4 の一段下げ先として M2 で必要） | M2 |
| 7 | YAML | JSON 先行（M1）＋自作サブセット（M3） | 未 | M1（JSON は確定でよい） |
| 9 | ルールの指定方法 | `--rules` のみで開始 | 未 | M1 |
| 10 | `languages` の別名・`nosemgrep` | 未定 | 未 | M3 |
| 11 | 同梱する宣言的ルール | 検証用の二重実装に留める | 未 | M2 以降 |
| 12 | taint の簡易版 | ロードマップ外 | 未（関連: `docs/DATAFLOW_ENGINE_DESIGN.md` 11章・未決事項10） | — |

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
- [x] PatCompiler: ラッパー 3 段の試行（そのまま → `begin <P> end` → `begin __rawpaco_w__ := <P> end`）、パターン IR への変換、`ts_tree_delete` → `src/Decl/PatCompiler.pas`（interface は Opus、implementation は Qwen。差し戻し 1 回）。`exprParens` はパターン側で除去する。式だけの `statement` 1 個は式パターンにする。ellipsis だけのパターン・空のパターンは読み込みエラー
- [x] パターン IR のダンプ機能とゴールデンテスト → 開発者向けオプション `--dump-pattern=FILE`（関数本体は Qwen）。`tests/decl/dump/*.pat` と `.expected` の 14 件を `run_tests.sh` で照合（期待値を壊すと落ちることを確認済み）
- [x] PatMatcher: 名前付きの子の比較、`comment` / `pp` の除外、葉の比較規則、メタ変数の単一化、子の列の ellipsis（バックトラック）、`exprParens` の透過 → `src/Decl/PatMatcher.pas`（interface は Opus、implementation は Qwen。コンパイルエラー 2 点は Opus が修正）。`Foo()` に `exprArgs` が無いことへの対処（ellipsis だけの子を持つノードは「無い」にも一致）は Opus が追加。`$...X` の 2 回目以降はソーステキストの完全一致で比べる（M3 の `$...ARGS` で見直す）。開発者向けオプション `--match-pattern=PAT ファイル...`（関数本体は Qwen）と、`tests/decl/match/` のゴールデン 9 件
- [x] Pascal 固有: 文の位置の括弧なし呼び出し、`raise;` の専用ノード → IR の `pkBareRaise` と `PatCompiler.IsBareRaiseError` / `HasErrorOtherThanBareRaise`（interface は Opus、実装は Qwen。レビューで Opus が 3 点修正）。`raise;` の ERROR は両側で普通の子として扱い、エラーの門番はこの形だけを通す。括弧なしの呼び出しは `PatMatcher.MatchParenlessCall`（親が `statement` のときだけ）。ゴールデン: 照合 6 件、ダンプ 1 件を追加
- [x] JSON ルールローダ（`fpjson`）。未知キー・未対応機能キーはエラー（終了コード 2）→ `src/Decl/RuleFile.pas`（interface は Opus、implementation は Qwen。レビューで Opus が 5 点修正）。決めたことは設計書 4.6 に追記。開発者向けオプション `--dump-rules=FILE` と、`tests/decl/load/` のゴールデン 30 件（読み込める 5 件、エラー 25 件）。ネイティブのルールとの ID 重複は次のアダプタのタスクで扱う
- [x] `IRawpacoRule` アダプタ（`InterestedNodeTypes = root`）と `--rules=<file|dir>`、ID 重複エラー、`--only` / `--exclude` との連携 → `src/Decl/DeclRule.pas`（interface は Opus、implementation は Qwen。差し戻しなし、Opus の修正は警告 1 点のみ）。`TLintContext` に `ReportAt` と `Source` を追加（Opus）。CLI の配線と README も Opus。`tests/decl/cli/` に lint 全体を通したゴールデン 14 件
- [x] `message` の `$X` 補間 → `src/Decl/MsgInterp.pas`（interface と単体テスト `tests/unit/TestMsgInterp.lpr` 31 件は Opus、implementation は Qwen。直したのは変数名 1 点と自明なコメントだけ）。組み込み（アダプタでの補間、ローダでの未束縛の参照の警告）は Opus。ゴールデン: lint 全体 1 件（`tests/decl/cli/interp`）、読み込み 1 件（`ok_message_unbound`）
- [x] テスト: `tests/decl/<機能>/` に positive / negative、読み込みエラーのテスト → 各タスクで追加済み: `dump` 17 件、`match` 16 件、`load` 31 件、`cli` 16 件、単体 22 + 31 件。どの照合のゴールデンにも一致すべきコードと一致してはいけないコードの両方を入れている
- [x] 完了条件: DEFENSE-001 相当を宣言的ルールで書き、既存サンプルでネイティブ版と同じ結果になる → `tests/decl/equiv/defense001.json`（単一の `pattern` のルール 4 本の和）。既存サンプル 7 件で、検出する構文がネイティブ版と一致（negative 4 件すべて、positive 0 件）。報告位置は try の行と except の行で違う（`focus-metavariable` は M2）。そのために例外ハンドラ用の 4 番目のラッパーを追加（設計書 4.2）。fpc-source 全体の比較は作業ログを参照。**M1 完了（2026-11-19）**

### M2 合成（目安 1,000〜1,500 行）

- [x] `patterns` / `pattern-either` / `pattern-not` / `pattern-inside` / `pattern-not-inside` と範囲演算・束縛の両立判定 → `src/Decl/Formula.pas`（interface は Opus、implementation は Qwen。レビューで Opus がバグ 2 点を修正）。読み込みは `RuleFile.ParseFormula`（Opus）。決めたことは設計書 4.4 に追記。ゴールデン: 読み込み 12 件、lint 全体 1 件（`tests/decl/cli/combine`、ルール 8 本）。Linux / Windows CI 緑（run 44459076403）
- [x] 文の並びのパターン（`block` / `statements` / `blockTr`、条件コンパイル指令をまたがない）→ `PatMatcher.FindSequenceMatches`（Qwen。1 回目は思考だけで本文が空。プロンプトを短くした 2 回目を採用し、レビューで Opus が束縛の退避の位置を修正）。入れ子への探索と重要度の一段下げ（`DeclRule`、`Formula` の印の持ち回し）は Opus。`;` の問題は PatLexer で補う方に決めた。決めたことは設計書 4.3 に追記。ゴールデン: 照合 4 件、ダンプ 1 件、読み込み 3 件、lint 全体 2 件。Linux / Windows CI 緑（run 44469718256）。`go_deeper_stmt` は既定で有効、入れ子内だけの一致は重要度を一段下げる（#4）。M1 での実測: 文の位置の `...` は後ろに `;` が無いとパースできない（`...;` なら可）。opengrep の他言語のルールは `;` なしで書くことが多いので、PatLexer で補うかルール作者に `...;` を求めるかをここで決める
- [x] `svInfo` を `svWarning` の前に追加し、`--fail-on=info` を受け付ける（#6）→ Opus が直接実装。text / json は `info`、github は `::notice`。宣言的ルールの `INFO` / `LOW` を受け付ける。ゴールデン: 読み込み 1 件（`ok_severity_info`、旧 `err_severity_info`）、lint 全体 5 件（`tests/decl/cli/info_*`）
- [~] `pattern-regex` / `pattern-not-regex` / `metavariable-regex` → `src/Decl/DeclRegex.pas`（interface と単体テスト 28 件は Opus、implementation は Qwen。レビューで Opus が無限ループを修正）。合成・読み込みへの組み込みは Opus。#5 は「識別子なら既定で大文字小文字を無視」に決定。ゴールデン: 読み込み 11 件、lint 全体 1 件（`tests/decl/cli/regex`）。最初の CI（run 44479844045）は Windows の単体テストで `RegExpr` が見つからず失敗（単体テストのコンパイルに FPC パッケージの検索パスを渡していなかった）。修正済み、push・CI 待ち
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

- 2026-11-19 / Opus（ローカル）+ Qwen: 正規表現の演算子。オーナー判断で #5 を「束縛が識別子 1 個なら既定で大文字小文字を無視、それ以外は区別」に決めた。#8 の再評価として、RegExpr の必要な機能（ModifierS / M / I、Exec / ExecNext、長さ 0 の一致の後も ExecNext が進むこと、ERegExpr）を実機で確かめ、RegExpr のまま進めた。tree-sitter に依存しない部分を新ユニット `DeclRegex` にし、単体テストを Opus が仕様から先に書いた。Qwen の実装で直したのは、`FindRegexRanges` のループ条件が毎回先頭から探し直す `Exec` で、一致があると終わらない点（単体テストがそのままでは止まらない）と、未使用の変数、コードをなぞるコメント。決めたこと: `metavariable-regex` は束縛のテキストの先頭に固定（ルール5）、束縛されていない一致は落とす、名前が同じ `patterns` で束縛されなければ読み込みエラー。`pattern-not-regex` は範囲がどちら向きに含まれても除く。fpc-source 全体にテスト用の 4 ルールを当て、クラッシュなし、約 1 分 26 秒。結果: make / make test（単体 29 + 31 + 28 件）/ make selflint 緑。次の一手: push して CI → `focus-metavariable` と終了位置

- 2026-11-19 / Opus（ローカル）+ Qwen: 文の並びのパターン。3 つのコミットに分けた。(1) `svInfo` と `--fail-on=info`（入れ子の一致を一段下げる先として先に必要。github 形式は `::notice`）。(2) PatLexer: 行に単独で括弧の外の `...` / `$...X` に `;` を補う（ルール作者に `...;` を求めない方に決めた。opengrep の他言語のルールの書き方に合わせるため）。単体テスト 7 件追加。(3) 照合: 対象は `block` / `statements` / `blockTr` の子で、`pp` 指令・`raise;` 以外の ERROR・MISSING で区間に分け、一致は 1 区間に収める（条件コンパイル指令に限らず止める。ルール5）。入れ子への探索は、直接の照合が失敗したときに最後の文の項目だけに使い、印（`TPatMatch.Deeper`）を合成で持ち回して、アダプタが範囲ごとに全部印付きなら一段下げて注記を付ける。Qwen は 1 回目、約 2 万トークンを思考に使い本文が空のまま stop で終わった。`tools/qwen-gen.bb` を本文が空なら失敗にするよう直し、既存ファイル全文の代わりに必要な宣言だけを渡す短いプロンプトで 2 回目を採用。直したのは、入れ子への探索で束縛を退避する位置が遅く、失敗した候補の束縛が次の候補に残る点と、未使用の変数。fpc-source 全体で「生成して同じブロックで解放」「解放されない」の 2 ルール（M2 のテスト用、同梱しない）を当て、クラッシュなし、約 1 分 14 秒、735 件（うち入れ子でだけ見つかったもの 483 件）と 1,545 件。抜き取りで 3 件確認し、いずれも照合としては正しい（1 件は `Destroy` で解放しているもので、テスト用ルールの除外に無いだけ）。結果: make / make test（単体 29 + 31 件）/ make selflint 緑。push 後の CI（run 44469718256）も Linux / Windows とも緑。次の一手: `pattern-regex` / `metavariable-regex`（#5 の判断が要る）

- 2026-11-19 / Opus（ローカル）+ Qwen: M2 の論理結合。合成の木と評価を新ユニット `Formula` に置き、照合器から束縛の同値判定 `BindingsEquivalent` を公開した（単一ノードは構造、`$...X` はテキストの一致）。`patterns` の中は「正の項の積 → pattern-inside → pattern-not-inside → pattern-not」の順に適用し、否定の項が inside から受け継いだ束縛を使えるようにした。正の項どうしの積は、どちら側の一致でも相手の両立する一致の範囲に入るものを残す。いずれも設計書 4.4 の表の素直な読みで、opengrep との食い違いは差分テスト（7.3）で洗う。否定・inside は `patterns` の直下だけで受け付け、`pattern-either` の中では読み込みエラー（opengrep の挙動を差分テストで確かめるまで。ルール5）。Qwen の実装は構造が仕様どおりだったが、直したのは 2 点: (1) 途中経過の変数が外側の関数のもので、`patterns` の中の `pattern-either` の中の `patterns` で外側の途中経過を上書きする、(2) 最初の正の項を `Cur = nil` で判定していたため、最初の項が 1 件も一致しないと 2 番目の項の結果がそのまま残る（誤検知の方向）。どちらも回帰用のルールを `tests/decl/cli/combine/rules2.json` に入れた。結果: make / make test / make selflint 緑。fpc-source 全体で DEFENSE-001 相当の宣言的ルールは 53 件のまま（M1 と同じ。約 1 分 33 秒）。push 後の CI（run 44459076403）も Linux / Windows とも緑。次の一手: 文の並びのパターン

- 2026-11-19 / Opus（ローカル）: オーナー判断により、M1 の比較で見つけたネイティブ DEFENSE-001 の誤検知を修正。`exceptionHandler` の直下に「子が `kRaise` だけの ERROR」があれば、body が `;` でも報告しない（宣言的ルール側の `IsBareRaiseError` と同じ形。ネイティブルールを Decl ユニットに依存させないため、判定は `RuleDefense001.pas` に持たせた）。positive サンプル `reraise_handler.pas` を追加。fpc-source 全体で DEFENSE-001 は 68 → 57 件（想定どおり 11 件減）、他のルールの件数は変化なし。結果: make / make test / make selflint 緑。push 後の CI（run 44455251420）も Linux / Windows とも緑。次の一手: M2

- 2026-11-19 / Opus（ローカル）: M1 の完了条件。ネイティブの DEFENSE-001 は 3 つの形（`except end`、`except ; end`、本体が `;` だけの `on ... do`）を報告する。M1 は単一の `pattern` だけなので、宣言的ルール 4 本（ハンドラは変数ありとなしで 2 本）の和で比べた。ハンドラ 1 個のパターン `on $V: $T do ;` はどのラッパーでもパースできず、ハンドラの並びの中に ellipsis も置けない（`...` が識別子になり、ハンドラと並べられない）ので、4 番目のラッパー `begin try except <P> end end` を追加した（Opus が直接実装。設計書 4.2 に追記）。`$E` は #3 の決定どおり 16 進と曖昧でエラーになるので `$V` を使った。既存サンプル 7 件では検出する構文がネイティブ版と完全に一致した（報告位置は try 行と except 行の違いだけ）。fpc-source 全体ではネイティブ 68 件、宣言的 53 件で、宣言的だけが出すものは 0 件。差の 15 件は全部分類できた: (1) 11 件は `on E: X do raise;`。裸の `raise;` が extra な ERROR になり、ハンドラの body フィールドが `;` だけになるため、**ネイティブ版が「空のハンドラ」と誤検知していた**。宣言的ルールは raise の ERROR を子として数えるので正しく一致しない（`tests/decl/equiv/reraise_handler.pas` で再現。ネイティブは 2 件、宣言的は 0 件）。(2) 4 件はファイルの大部分が 1 つの extra な ERROR になっている領域の中の、本物の空の except。宣言的エンジンは「エラーの中は照合しない」方針で飛ばす。結果: make / make test / make selflint 緑。push 後の CI（run 44412760609）も Linux / Windows とも緑。**M1 完了**。次の一手: ネイティブ DEFENSE-001 の誤検知の修正（オーナー判断）→ M2 着手前の続行判断はまだ不要（M1〜M2 の後）

- 2026-11-19 / Opus（ローカル）+ Qwen: `message` の `$X` 補間。補間は tree-sitter に依存しない新ユニット `MsgInterp` に切り出し、束縛を「キーと値の文字列の組」で受け取る形にした。単体テストを Opus が仕様から先に書き、Qwen の実装は 1 回で 31 件すべて通った。直したのは、ローカル変数 `pos` が `SysUtils.Pos` を隠していた点（RuleFile と同じ癖）と、コードをなぞるだけのコメント 2 か所。仕様の判断: `$X` と `$...X` は照合器では同じ名前の束縛だが、メッセージでは書き分けたとおりにだけ置き換える。束縛されていない参照は残して警告し、エラーにはしない（M2 の pattern-either のため）。束縛テキストの空白・改行はまとめる（複数行の `Log('a',\n B + 1)` が 1 行に収まることをゴールデンで確認）。前回の教訓から、標準エラーの通知は標準出力と混ざらない `--dump-rules` のテストで確かめた。結果: make / make test（単体 22 + 31 件、lint 全体 15 件を含む）/ make selflint 緑。push 後の CI（run 44408701800）も Linux / Windows とも緑（TestMsgInterp 31 件と interp のゴールデンが両方で通過）。次の一手: M1 の完了条件（DEFENSE-001 相当の宣言的ルールで、既存のサンプルがネイティブ版と同じ結果になること）

- 2026-11-19 / Opus（ローカル）+ Qwen: `IRawpacoRule` アダプタと `--rules`。宣言的ルールの一致はノードではなくバイト範囲と開始位置で返るので、`TLintContext.ReportAt`（位置で報告）と、照合器に渡す `Source` プロパティを足した（既存の `Report` は `ReportAt` を呼ぶ形にしたので、ネイティブのルールの出力は変わらない。make test で確認）。宣言的ルールは `--only` / `--exclude` の ID 検査より前に登録する（`SetRuleFilter` は登録済みの ID だけを既知とみなすため）。ネイティブとの ID の衝突は大文字小文字を無視して判定する。ディレクトリ指定は直下の `*.json` を `CompareStr` の名前順で読み、再帰しない。Qwen の実装は 1 回で仕様どおりで、直したのはコンパイラの警告 1 点（管理型の関数結果の初期化）だけ。テストを作る中で、標準出力の診断と標準エラーの通知を混ぜて比べると、バッファリング次第で順序が変わりうることに気づいた（実際に、先に書いた通知が後に出た）。通知のテストは診断の出ない対象に変えた。最初の push（run 44367968374）は Windows で 7 件落ちた。Windows の checkout で `args` が CRLF になり、最後の引数（対象ファイル）に `\r` が付いて開けなかったため。ランナーで `\r` を落とすよう直し、手元で `args` を CRLF にして 14 件通ることを確かめた。結果: make / make test（lint 全体 14 件を含む）/ make selflint 緑。修正後の CI（run 44369045068）は Linux / Windows とも緑（lint 全体 14 件が両方で通過）。次の一手: `message` の `$X` 補間

- 2026-11-19 / Opus（ローカル）+ Qwen: JSON ルールローダ。fpjson は既存の RawpacoConfig.pas で Linux / Windows とも確認済みのメソッド（GetJSON、JSONType、Count / Names / Items、AsString / AsBoolean）だけに限定して Qwen に依頼した（CLAUDE.md ルール1）。仕様の判断は 3 点: (1) `INFO` / `LOW` は M2 で `svInfo` が入るまで読み込みエラー（`svWarning` に寄せると作者の意図より重く出て CI を落としうる）、(2) 文の並びのパターンは M2 まで読み込みエラー（照合器が空の結果を返し「安全」に見えるため）、(3) ID は英数字・`_`・`-`・`.` に限る（`--only` のカンマ区切りと衝突させない）。Qwen の出力は構造が仕様どおりだったが、直したのは 5 点: 他言語のルールを飛ばすとファイル全体の読み込みが空のエラーで失敗する、`Obj.Items[0].AsString` が先頭のキーが文字列でないと例外になる、severity の検査が仕様の順序より後ろでパターンを漏らす経路がある、重複チェックで for ループの変数 `J` を入れ子で再利用していた（コンパイルエラー）、ローカル変数 `Pos` が `SysUtils.Pos` を隠す。`languages` の検査が "pascal" を見つけた時点で打ち切られ、後ろの要素の型を見ていなかったのも直した。ゴールデンの期待値をわざと壊すと落ちることを確認済み。結果: make / make test（ルール読み込み 30 件を含む）/ make selflint 緑。push 後の CI（run 44365788107）も Linux / Windows とも緑（ルール読み込み 30 件が両方で通過）。次の一手: `IRawpacoRule` アダプタと `--rules`

- 2026-11-19 / Opus（ローカル）+ Qwen: Pascal 固有の扱い（括弧なしの呼び出し、`raise;`）。まず fpc-source 3.2.2+dfsg-49 を入れ直し、全ルールの基準値の再現を確認した（HANDOFF.md）。プローブで木を実測した結果、`raise;` は子が `kRaise` だけの extra な ERROR で、属する並びの中か、属するフィールドの直前の兄弟として現れる。extras は子の列から除いていたので、パターン側では `raise;` が読み込めず、対象側では見えなかった。そこでこの形だけを両側で普通の子として扱う設計にした（設計書 4.3 の表に追記）。Qwen には差し替える関数だけを出力させ、Opus が組み込んだ。組み込み用のスクリプトが interface の宣言行にも一致してファイルを壊したので、git から戻してやり直した（検索を implementation 以降に限定）。レビューで直したのは 3 点: `TryWrapper` のぶら下がり else（文・式のラッパーでエラー検査が素通りになっていた）、`MatchList` の 2 つの経路で `Result` が未設定のまま読まれていたこと、変数の初期化漏れ。`$C` は #3 の決定どおり 16 進と曖昧でエラーになることを、サンプルを書く中で再確認した（`$COND` に変更）。`;` の無いパターン `raise` は式のラッパーで識別子として読まれ、何にも一致しない（従来からの挙動。設計書に明記）。fpc-source 全体で新しいパターンを流し、クラッシュが無いことと、1 パターンあたり約 48 秒であることを確認した。`raise;` の取りこぼしを grep と突き合わせると、すべて文字列・コメントの中か、tree-sitter-pascal がファイルの大部分を 1 つの extra な ERROR にしている領域だった（例: `fcl-xml/src/xmltextreader.pp` の 816〜3982 行）。後者は「エラーの中は照合しない」方針による既存の挙動で、括弧なしの呼び出しや他のパターンも同じく取りこぼす。M2 の fpc-source 実測では、この取りこぼしの量も数えること。結果: make / make test（照合 15 件、ダンプ 15 件）/ make selflint 緑。push 後の CI（run 44360972133）も Linux / Windows とも緑（新しい照合 6 件も両方で通過）。次の一手: JSON ルールローダ

- 2026-11-17 / Opus（ローカル）+ Qwen: PatMatcher。対象側の木を実測し、`pp` も `ERROR` も extras であることを確認した。そのため extras を飛ばすだけでは ERROR を見落とすので、照合の入口で `ts_node_has_error` を見る仕様にした。Qwen の実装は照合ロジック（バックトラック、`Copy` による束縛の退避、範囲束縛）が 1 回で正しかった。直したのはコンパイルエラー 2 点（本体のない前方宣言、`case` の分岐の `begin`/`end` 漏れ）と警告 1 点で、いずれも Opus が修正。ゴールデンテストで、`Foo()` には `exprArgs` が無いために `Foo(...)` が一致しないことを発見した。仕様の漏れなので Opus が規則を追加し、設計書 4.3 の表にも追記した。`try ... except end;` のパターンで空の except を検出でき、M1 の完了条件（DEFENSE-001 相当）の見通しが立った。`LintDriver.ReadFileAsString` を interface に公開した。結果: make / make test（単体 22 件、ダンプ 14 件、照合 9 件）/ make selflint 緑。push 後の CI（run 43910340637）も Linux / Windows とも緑（照合 9 件ずつ通過）。次の一手: Pascal 固有（括弧なしの呼び出し、`raise;`）→ JSON ルールローダ

- 2026-11-17 / Opus（ローカル）+ Qwen: PatCompiler とパターン IR のダンプ。一時的なダンププログラム（`src/probe.lpr`、削除済み）で、ラッパーで包んだパターンの木の形を実測してから interface を書いた。このとき追加した TSBindings の 5 関数のリンクと動作も確認できた。Qwen の 1 回目は、木を消した後に TSNode を使う（解放済みの参照）、外側の変数の宣言順によるコンパイルエラー、`Wrapper` の設定漏れ、PAnsiChar の比較の問題があり、差し戻した。2 回目は指摘をすべて反映し、警告なしでコンパイルできた。`--dump-pattern` の関数は 1 回で採用（変数名 `Text` を `PatText` に変える修正のみ Opus）。ゴールデンテストを作る過程で 2 点を発見: (1) `$A`〜`$F` の 1 文字のメタ変数も #3 の決定どおりエラーになる（opengrep のルールでよく使う名前なので、M3 の互換性一覧に明記する）、(2) 文の位置の `...` は `;` が必要（M2 の文の並びのタスクに記録）。結果: make / make test（単体 22 件、ゴールデン 14 件）/ make selflint 緑。push 後の CI（run 43907990022）も Linux / Windows とも緑（Windows でもゴールデン 14 件通過）。次の一手: PatMatcher の interface と作業指示

- 2026-11-17 / Opus（ローカル）+ Qwen: M1 の最初の 3 タスク。PatLexer は interface を Opus、implementation を Qwen が担当。1 回目は papimela の qwen-gen.bb（`num_ctx` 16384）を使い、出力が途中で切れた。単引用符の文字定数の誤記と、開いた配列引数への `SetLength` もあった。→ interface を `TStringArray` に直し、`num_ctx` 65536 で途中切れを検出する `tools/qwen-gen.bb` を新設して再依頼。2 回目はレビューで機械的な修正を Opus が直接入れた（`Char` 引数、関数末尾の `end.`、変数名 `Out`、`(*)` の誤認、理由コメント）。単体テストで、Opus の `(*)` 修正の誤りと、テスト期待値の誤り（`$FF` は仕様上エラー）が見つかり修正。TSBindings の 5 宣言は Qwen が 1 回で正解。結果: make / make test（単体テスト 22 件含む）/ make selflint 緑。push 後の CI（run 43902463083）も Linux / Windows とも緑。次の一手: push して CI 確認 → PatCompiler（ラッパー 3 段の試行とパターン IR）の interface と作業指示

- 2026-11-17 / Opus（ローカル）: ローカル main を `claude/exciting-einstein-hw4zfz` に fast-forward。ベースライン（make / test / selflint）緑。M0 の確認 4 項目を完了。`RegExpr` 検証プログラムは Qwen（qwen3.8-27b-64k、ollama HTTP API。呼び出しは papimela の `tools/qwen-gen.bb` を `PAPIMELA_QWEN_MODEL` 指定で流用）に書かせ、レビュー 1 回で採用・実行した（リポジトリには入れていない）。続けてオーナーと協議し、★の #3・#4・#8 と、#4 に伴い #6 を決定（設計書 英→日 に反映）。push は未実施。M0 完了。次の一手: M1 の最初のタスク（`src/Decl/` 作成と TSBindings への関数追加）の作業指示を書く
- 2026-11-16 / Claude（クラウド）: 設計書を作成し、オーナーが案 (d) を採用。英語版を正とし `_jp` を併置。本ファイルを新規作成。実装は未着手。次の一手: ローカルセッションで M0 に着手
