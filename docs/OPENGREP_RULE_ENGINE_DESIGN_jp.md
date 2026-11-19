# opengrep ルールエンジンの取り込み: 実現可能性の検討と設計

- 作成日: 2026-11-16
- 位置づけ: 検討・設計ドキュメント（実装は未着手。ソースコードは一切変更していない）
- 調査対象: opengrep/opengrep `main` の commit `526deafe`（2026-11-13）。rawpaco は commit `ffb5c9c` 時点
- 言語について: 英語版 `docs/OPENGREP_RULE_ENGINE_DESIGN.md` が正（canonical）。本書は参照用の日本語版で、更新は英語版を先に行う（HANDOFF.md の規約）
- 決定事項（2026-11-16、オーナー判断）: 推奨案 (d) で進める。本書を `docs/` の命名規約に揃え、英語版を正とする（10章の 1・2 は決着済み）

本書では、根拠の強さを次の3つで書き分ける。

- **【実測】** この調査で実際にコマンドを実行して確認したこと
- **【ソース確認】** opengrep または rawpaco のソースを読んで確認したこと
- **【未確認】** 既知の知識または推測。実装前に裏取りが必要なこと

---

## 0. 結論と推奨案

**結論: 「部分的に可能」。「全部ぶっこむ」は rawpaco への取り込みとしては不可能に近く、推奨しない。**

1. **opengrep 本体をそのまま持ち込んでも Pascal は解析できない。** opengrep の対応言語に Pascal/Delphi は無い【ソース確認】。エンジンは tree-sitter の CST ではなく、言語ごとに手書きした変換器が作る Generic AST の上で動く。したがって本体をリンクしても外部プロセスで呼んでも、Pascal 用の変換器（OCaml）を誰かが書かない限り、使えるのは構文を理解しない `generic` / `regex` モードだけである。
2. **全機能の FPC 再実装は規模が合わない。** opengrep のエンジン中核（ルール・マッチング・検索・taint・IL・解析・名前解決・autofix・Generic AST 定義）は OCaml で約 6.9 万行ある【実測】。rawpaco は全体で約 5,800 行【実測】。taint モードだけで約 1.9 万行あり、IL・CFG・データフロー・定数伝播・名前解決に依存する。
3. **現実的なのは「ルール言語のサブセットを FPC で再実装し、tree-sitter-pascal の CST 上で直接動かす」こと。** 検索モード（`pattern` / `patterns` / `pattern-either` / `pattern-not` / `pattern-inside` / `pattern-not-inside` / `pattern-regex` / `metavariable-regex` / `metavariable-pattern` / `focus-metavariable`、メタ変数、ellipsis）は実装できる見込みが高い。パターン断片が tree-sitter-pascal でパースできることは、ラッパーと前処理を条件に確認した【実測、4.2節】。

**推奨案（2026-11-16 に採用決定）: 案(d)「opengrep 互換サブセットの FPC 再実装」を、既存のネイティブルールと併存する「宣言的ルール層」として段階導入する。**

- 取り込む: 検索モードの主要演算子、メタ変数、ellipsis、メッセージ補間、SARIF 出力、後段で `fix:` による autofix
- 取り込まない: taint モード、join モード、ファイル間解析、型付きメタ変数、定数伝播・シンボル伝播、SCA、extract モード、generic（spacegrep/aliengrep）モード
- 既存の 13 ルールは置き換えない。MEM-001 や HALLUC-001 のような独自解析はパターン言語では書けない

**正直な注意点を3つ。**

- できあがるのは「opengrep のルール形式の Pascal 方言」であって opengrep そのものではない。opengrep は `languages: [pascal]` を知らないので、rawpaco 用のルールファイルを opengrep で実行して挙動を突き合わせることはできない。**互換性は機械的に検証できない**（7章）。
- 既存の Semgrep/opengrep ルール資産に Pascal 向けのものは無い。つまり「取り込めば既存ルールがそのまま使える」という利得は発生しない。得られるのは「ルールを Pascal コードではなく YAML で書ける」ことである。
- 「本当に全機能（taint 含む）が欲しい」なら、唯一の現実的な道は逆方向、つまり **opengrep 側に Pascal 言語サポートを追加する**こと（案 b'、2.3節）。これは OCaml での別プロジェクトになり、rawpaco の開発ルール（FPC 実装、false positive 回避優先）の管理外になる。どちらを取るかはオーナー判断として 10章に挙げた。

---

## 1. opengrep ルールエンジンの構成

### 1.1 全体像【ソース確認】

opengrep は Semgrep CE のフォークで、OCaml 5.3 で実装されている（`OPENGREP.md`）。ライセンスは LGPL-2.1（`LICENSE` / `COPYRIGHT`）。Linux / macOS / Windows 向けの自己完結バイナリを配布している（`README.md`）。

処理の流れは次のとおり。

```
ルール YAML ──(Parse_rule)──> Rule.t（formula の木）
対象ソース ──(言語別パーサ)──> 言語別 CST/AST ──(言語別変換器)──> Generic AST
パターン文字列 ──(同じ言語別パーサ。メタ変数・ellipsis 対応に拡張した文法)──> Generic AST
        Generic AST 同士を Generic_vs_generic で照合 ──> (範囲, メタ変数束縛) の集合
        formula を範囲演算で合成（Match_search_mode） ──> 検出結果
        taint モードは Generic AST → IL → CFG → データフロー（src/tainting）
```

重要なのは、**マッチャは tree-sitter の木を直接見ていない**点である。言語ごとに `Parse_<lang>_tree_sitter.ml` という手書きの変換器があり、そこで構文の揺れ（括弧、糖衣構文など）を吸収してから照合する。

### 1.2 規模【実測】

`.ml` ファイルの行数（テストを含む、`.mli` は除く）。

| ディレクトリ | 行数 | 役割 |
|---|---:|---|
| `src/rule` | 2,128 | ルールのデータ型（`Rule.ml` の `formula` など） |
| `src/parsing` | 5,257 | ルール YAML のパース（`Parse_rule.ml` ほか） |
| `src/matching` | 7,258 | パターン照合。`Generic_vs_generic.ml` 単体で 4,314 行 |
| `src/engine` | 10,371 | 検索モード・taint モードの駆動、メタ変数制約、範囲演算 |
| `src/tainting` | 19,006 | taint 解析（関数シグネチャ、形状、不動点計算など） |
| `src/il` | 1,956 | 中間言語 |
| `src/analyzing` | 9,415 | CFG、データフロー、定数伝播など |
| `src/naming` | 3,418 | 名前解決 |
| `src/fixing` | 1,302 | autofix |
| `src/call_graph` | 1,648 | 呼び出しグラフ |
| `libs/ast_generic` | 7,238 | Generic AST の定義 |
| **合計** | **約 69,000** | 言語フロントエンド、CLI、出力、SCA などは含まない |

言語フロントエンド1つの規模の目安: Lua の変換器が 824 行、Ruby が 2,585 行＋1,036 行、手書きパーサの VB.NET が 5,935 行。

### 1.3 ルール言語の要素【ソース確認】

`Rule.ml` の `formula_kind` は `P`（葉パターン）/ `And` / `Or` / `Not` / `Inside` / `Anywhere` で、これに条件（`CondEval` / `CondRegexp` / `CondType` / `CondAnalysis` / `CondNestedFormula` / `CondName` ほか）と `focus` が付く。葉パターン（`Xpattern.ml`）は `Sem`（構文パターン）/ `Spacegrep` / `Aliengrep` / `Regexp` の4種。モードは `search` / `taint` / `extract` / `steps` / `sca`。

ルールパーサが受け付けるキーは次のとおり: `pattern` `patterns` `pattern-either` `pattern-not` `pattern-inside` `pattern-not-inside` `pattern-regex` `pattern-not-regex` `metavariable-regex` `metavariable-pattern` `metavariable-comparison` `metavariable-type` `metavariable-analysis` `focus-metavariable` `fix` `fix-regex` `pattern-sources` `pattern-sinks` `pattern-sanitizers` `pattern-propagators`。

合成の意味論は「範囲とメタ変数束縛の組」に対する演算である（`Range_with_metavars.ml`）。包含判定と束縛の両立性で絞り込み、否定側は種類によって判定が違う（`pattern-not-inside` は包含、`pattern-not` は範囲の一致、正規表現はどちら向きの包含でも可）。文の並びの照合には、入れ子のブロックへ潜る `go_deeper_stmt`、式の内側へ潜る `go_deeper_expr` というオプションがある。

### 1.4 確認できなかったこと【未確認】

- join モードの実装位置。CHANGELOG に `join_rule` への言及があるので機能は存在するが、OCaml 側か Python 側かは追っていない。Semgrep では Python 側の実装だったというのが既知の知識
- ルールファイルとして JSON を受け付けるか。Semgrep は受け付けるというのが既知の知識だが、この commit では確認していない
- opengrep のルール集（opengrep-rules）のライセンス。Pascal 向けルールが存在しないので本件には影響しない

---

## 2. 「全部ぶっこむ」の取りうる形の比較

### 2.1 一覧

| 案 | 内容 | 技術的可否 | Pascal を構文として解析できるか | 規模感 | 評価 |
|---|---|---|---|---|---|
| (a) | OCaml 本体をライブラリとしてリンク・同梱 | 極めて困難 | できない（変換器が無い） | 特大 | **不採用** |
| (b) | opengrep を外部プロセスとして呼ぶ | 可能 | できない（`generic` / `regex` のみ） | 小 | 補助用途なら可。本件の答えにはならない |
| (b') | opengrep に Pascal サポートを追加して外部プロセスで使う | 可能 | できる | 大（OCaml） | 「全部」が必須なら唯一の道。別プロジェクト |
| (c) | ルール言語と意味論を FPC で全部再実装 | 事実上不可能 | できる | 特大（6.9 万行相当） | **不採用** |
| (d) | サブセットを FPC で再実装し CST 上で動かす | 可能 | できる | 中 | **推奨** |
| (e) | tree-sitter のクエリ（`.scm`）を宣言的ルール形式にする | 可能 | できる | 小 | 代替案。opengrep とは無関係 |

### 2.2 案(a): OCaml 本体をリンクする

不採用。理由は次のとおり。

- **Pascal のフロントエンドが無いので、リンクしても何も解析できない。** 結局 (b') と同じ OCaml の変換器を書く必要がある。
- **Windows ビルドと両立しない。** rawpaco の Windows CI は 32bit（i386-win32）で確定しており、64bit 経路は検証のうえ断念している（HANDOFF.md）。OCaml 5 系は 32bit のネイティブコード生成を持たない【未確認、既知の知識】。opengrep は OCaml 5.3 前提なので、32bit の rawpaco にはリンクできない。
- **リンクの難度が高い。** OCaml ランタイム（GC、OCaml 5 のドメイン）、PCRE2、opengrep 側が抱える tree-sitter ランタイムを FPC のリンカに通す必要がある。tree-sitter ランタイムは rawpaco が `vendor/` に固定している v0.24.7 とシンボルが衝突する。mingw のランタイムを通すだけで CI を 18 回往復した経緯（HANDOFF.md）を踏まえると、見通しは暗い。
- **CLAUDE.md ルール1 と噛み合わない。** cdecl 宣言は `vendor/` のヘッダと照合する決まりだが、opengrep は C の公開 API もヘッダも持たない。自前の C スタブを書くことになり、照合先が存在しない。
- **ライセンス。** LGPL-2.1 のコードを静的リンクした実行ファイルを配布する場合、利用者がライブラリ部分を差し替えて再リンクできる手段（オブジェクトファイルの提供など）を用意する義務が生じる（6条）。rawpaco は MIT で、現在は静的リンクの単一バイナリである。

### 2.3 案(b) と (b'): 外部プロセス

**(b) そのまま呼ぶ。** opengrep は `.pas` を `languages: [generic]` か `[regex]` でしか扱えない【ソース確認: `Xlang.ml`】。これらは Pascal の構文・コメント・文字列・大文字小文字の非区別を理解しないので、tree-sitter-pascal を持つ rawpaco より精度が下がる。false positive 回避を最優先とする CLAUDE.md ルール5 と相性が悪い。rawpaco に組み込む価値は薄く、利用者が別ツールとして並べて使えば済む。プロセス分離なのでライセンス上の影響は無い。

**(b') opengrep に Pascal を足す。** 必要な作業は次のとおり【未確認、Semgrep の言語追加手順についての既知の知識】。

1. tree-sitter-pascal の文法を、メタ変数と ellipsis を受け付けるように拡張した派生文法を作る
2. その文法から OCaml の CST 型を生成する
3. CST から Generic AST への変換器を OCaml で書く（`grammar.js` が 1,206 行なので、Ruby 相当の 2,000〜4,000 行と見積もる）
4. 言語の登録、テスト、upstream への提案または自前フォークの維持

これが通れば taint も autofix も含めて**本当に全部**が手に入る。ただし次の点で rawpaco の方針から外れる。

- 実装言語が OCaml になる。rawpaco の「FPC 自身で書く」という前提の外
- 文法を派生させるので、CLAUDE.md ルール2 のバージョン固定の対象が2系統になる
- 検出の精度方針を rawpaco 側で制御できない。Pascal 固有の罠（`with` 文、`{$IFDEF}`、マクロ、括弧なし呼び出し）への対処を Generic AST 変換器の中に入れることになる
- 配布物が2つのバイナリになる

### 2.4 案(c): 全部を FPC で再実装

不採用。6.9 万行相当の OCaml を移植する規模であり、しかも移植元は活発に変更されている（調査時点の最新 commit は3日前）。taint は IL・CFG・データフロー・名前解決・定数伝播の上に成り立っており、Pascal ではさらに型情報・ユニット間解決が無いと精度が出ない。rawpaco は型情報もシンボル表も持たない設計である（`docs/RULE_ENGINE_DESIGN.md` 2.3節）。

なお、OCaml のソースを Pascal に書き写す形の移植は LGPL-2.1 の派生物になり、その部分は MIT にできない（3章）。

### 2.5 案(d): サブセットの再実装（推奨）

4章以降で設計する。線引きは次節。

### 2.6 案(e): tree-sitter クエリ

vendoring 済みの `api.h` には `ts_query_*` の API がある【ソース確認】。S 式のクエリをルール形式にすれば、パターンのパーサを書かずに宣言的ルールが実現できる。ただしメタ変数の単一化（同じ `$X` が同じものを指す）、文の並びの ellipsis、ブール合成は自前で足す必要があり、ルールの書き味は Pascal のコード片ではなくノード種別名の列挙になる。依頼は opengrep のルールエンジンなので本書では採らないが、(d) のパターン前処理が難航した場合の退避先として記録する。

### 2.7 線引き: どこまでが現実的か

| 区分 | 機能 | 判断 |
|---|---|---|
| 取り込む（M1〜M3） | `pattern` / `patterns` / `pattern-either` / `pattern-not` / `pattern-inside` / `pattern-not-inside` | CST 上で実装可能 |
| | `pattern-regex` / `pattern-not-regex` / `metavariable-regex` | 正規表現の方言差あり（4.6節） |
| | `metavariable-pattern` / `focus-metavariable` | 実装可能 |
| | メタ変数 `$X`、`$_`、ellipsis `...`、名前付き ellipsis `$...ARGS`、文字列の `'...'`、深い式 `<... e ...>` | 実装可能。前処理が必要（4.2節） |
| | `message` の `$X` 補間、`severity`、`metadata`、`paths` | 実装可能 |
| 取り込む（M4） | `metavariable-comparison` | 整数・文字列リテラルと単純な比較に限定。Python 風の式の完全な評価はしない |
| | `fix:`（テキスト置換の autofix）、`fix-regex` | 実装可能。既定は適用せず提案のみ |
| | `metavariable-analysis` の entropy | 実装は容易だが優先度低 |
| 取り込まない | taint モード（`pattern-sources` ほか） | IL・CFG・データフローが必要。opengrep 互換にはならない |
| | join モード、ファイル間解析、`steps` | ファイル単位で完結する現行アーキテクチャの外 |
| | 型付きメタ変数、`metavariable-type` | 型情報が無い |
| | 定数伝播、シンボル伝播、別名の同値性 | 名前解決が無い。誤検知の源になる |
| | `extract` / `sca` / secrets の検証 | 対象外 |
| | `generic`（spacegrep / aliengrep）モード、他言語 | Pascal 専用ツールなので不要（CLAUDE.md ルール6 とも整合） |

taint について補足する。関数内に限った簡易版（代入を追うだけ）なら rawpaco 独自機能として将来作れる可能性はあるが、それは opengrep の taint モードとは別物であり、同じキー名（`mode: taint`）を名乗るべきではない。本書のロードマップには入れず、未決事項に留める。

---

## 3. ライセンス

法的助言ではない。配布形態を決める前に確認が必要な点として挙げる。

- rawpaco: MIT【ソース確認: `LICENSE`】。vendoring している tree-sitter と tree-sitter-pascal はそれぞれの `LICENSE` を同梱済み
- opengrep: LGPL-2.1【ソース確認】

| 案 | ライセンス上の扱い |
|---|---|
| (a) リンク | 配布物に LGPL-2.1 の義務（再リンク手段の提供、ライセンス文と著作権表示の同梱）がかかる。rawpaco 自身のソースは MIT のままにできるが、静的単一バイナリという現在の配布形態と相性が悪い |
| (b) (b') 外部プロセス | rawpaco には影響しない。opengrep のバイナリを同梱して再配布するなら、その部分について LGPL-2.1 の条件に従う。(b') で書く変換器は opengrep の派生物なので LGPL-2.1 |
| (c) (d) 再実装 | ルール形式と意味論という「仕様」を独自に実装する限り MIT のままにできると考える。ただし **opengrep の OCaml コードを書き写す・逐語的に移植することは派生物になる** |

(d) を採る場合の運用ルールを提案する。

- 実装は公開ドキュメントの仕様と、自分で書いたテストから起こす。opengrep のソースを見ながら移植する作業方法は取らない
- opengrep のテストデータ（`tests/` 配下のルールと対象ファイル）を rawpaco のリポジトリに複製しない
- 本書 1章の記述は挙動の事実確認のためにソースを読んだ結果であり、コードの複製は含まない

---

## 4. 設計

### 4.1 アーキテクチャ

```
                 ┌───────────── 既存（変更は最小限）─────────────┐
rawpaco.lpr ──> LintDriver.RunLint ──> ASTWalker ──> RuleRegistry ──> ネイティブルール 13 本
   │                                                     ▲
   │ --rules=<file|dir>                                  │ IRawpacoRule として登録
   ▼                                                     │
RuleFile（ローダ）──> 宣言的ルール（formula の木）──> DeclRule（アダプタ）
   │                         │
   │                         ├─ PatLexer    パターン文字列の前処理
   │                         ├─ PatCompiler tree-sitter-pascal でパースしパターン IR に変換
   │                         ├─ PatMatcher  パターン IR と対象 CST の照合
   │                         ├─ Formula     範囲演算によるブール合成、メタ変数制約
   │                         └─ Regex       正規表現の葉・制約
   ▼
Diagnostics（text / github / json に加えて sarif）
```

新規ユニットは `src/Decl/` 配下に置く想定（`Makefile` の `-Fu` と `RULE_SOURCES`、Windows CI の `fpc` 呼び出しへの追記が必要）。

### 4.2 パターンパーサ

パターンは対象と同じ tree-sitter-pascal（v0.10.2 固定）でパースする。文法は改変しない。これは CLAUDE.md ルール2 を守るための選択で、opengrep が取っている「メタ変数対応に文法を拡張する」方式は採らない。代わりに、パース前の文字列置換とラッパーで吸収する。

以下は `vendor/` のソースを gcc でビルドした検証プログラムで確認した結果である【実測】。

**(1) コード片はそのままではパースできない。**

| 入力 | 結果 |
|---|---|
| `X := TFoo.Create;` | ルート直下が `ERROR` |
| `Foo(A, B);` | `ERROR` |
| `A + B` | `ERROR` |
| `begin X := TFoo.Create; end` | エラーなし。`blockTr` > `assignment` |
| `begin __W := A + B end` | エラーなし。`assignment` の `rhs` が `exprBinary` |
| `procedure Foo; begin X := 1; end;` | エラーなし。`defProc` |
| `var X: Integer = 1;` / `type TFoo = class ... end;` / `uses A, B.C;` | エラーなし。それぞれ `declVars` / `declTypes` / `declUses` |

したがって、次の順でラッパーを試し、`ERROR` と `MISSING` を含まない最初の結果を採用する。

1. そのまま（宣言レベルのパターン）
2. `begin <P> end`（文、文の並び）
3. `begin __rawpaco_w__ := <P> end`（式）
4. `begin try except <P> end end`（`on $V: $T do ;` のような例外ハンドラ 1 個。**M1 で追加、2026-11-19**）。ハンドラは `except` の中にしか書けず、文としても式としてもパースできないが、複数のハンドラの中の 1 個を対象にするルールが書けないといけない（M1 の完了条件で必要になった）。`except` の中身が `exceptionHandler` ちょうど 1 個のときだけ受け付け、パターン IR はそのハンドラのノードにするので、そのハンドラが現れる場所ならどこにでも一致する。ハンドラの並びは並びのパターンなので M2 を待つ

どれでもパースできないパターンは、ルール読み込み時のエラー（終了コード 2）にする。黙って無効化しない（`rawpaco.json` の未知キーと同じ方針）。

2 で得た木が「式だけを持つ `statement` 1個」の場合は、式パターンとして扱う。`Foo($X)` というパターンが、文の位置の呼び出しにも式の中の呼び出しにも一致するようにするためである。

**(2) `$X` は 16 進リテラルと衝突する。**

| 入力 | 結果 |
|---|---|
| `begin $ABC := 1; end` | エラーなし。ただし `$ABC` は **`literalNumber`**（16 進数）になる |
| `begin X := $OBJ; end` | `ERROR` |
| `begin $X := $Y.Create; end` | `ERROR` |

Pascal では `$FF` が 16 進リテラルなので、メタ変数をそのまま文法に通すことはできない。前処理で次のように置換する。

- `$` + 英大文字またはアンダースコアで始まる名前 → メタ変数。識別子 `__rawpaco_mv_<名前>__` に置換する
- `$` + 数字で始まる並び → 16 進リテラル。そのまま残す（`$0FF` と書けば必ず 16 進になる）
- **`$ABC` や `$FACE` のように、名前が 16 進数字（`A`〜`F` と数字）だけで出来ているもの → 曖昧なので読み込みエラー**にする。メッセージで `$X` への改名か `$0ABC` 表記を案内する。**決定（#3、2026-11-17）:** ルールに rawpaco 独自のオプション `options: { pascal_hex_dollar: true }` を書いた場合は、そのルールに限り Pascal の字句に忠実に 16 進リテラルとして扱い、エラーにせず該当箇所ごとに標準エラーへ 1 行の警告を出す

3つ目は opengrep との非互換になる（opengrep では `$A` や `$E` は普通のメタ変数名）。推測でどちらかに倒すと、気づかれないまま意味の違うルールが動くので、エラーにする。

前処理は Pascal の文字列リテラルとコメントを読み飛ばす小さなスキャナとして書く。文字列の中の `$X` や `...` を置換してはいけないためである。

**(3) ellipsis `...` も置換が必要。**

| 入力 | 結果 |
|---|---|
| `begin Foo(...); end` | `ERROR` |
| `begin try ... except end; end` | `ERROR` |
| `begin Foo(MV_X, MV_ELL); end` | エラーなし。`exprArgs` の子として `identifier` が2つ |
| `begin try MV_ELL; except end; end` | エラーなし。`statements` > `statement` > `identifier` |
| `begin MV_X := TStringList.Create; MV_ELL; MV_X.Free; end` | エラーなし |
| `begin MV_X := TStringList.Create; MV_ELL MV_X.Free; end`（ellipsis の後に `;` なし） | `ERROR`【M1 で実測】 |

`...` を識別子 `__rawpaco_ell__` に置換すれば、引数の位置と文の位置ではパースできる。`$...ARGS` は `__rawpaco_mvell_ARGS__` に置換する。

**(4) 識別子が置けない位置の ellipsis は、位置ごとに別の綴りが必要。**

| 入力 | 結果 |
|---|---|
| `type MV_T = class(MV_P) MV_ELL end;` | `ERROR` |
| `type MV_T = class(MV_P) MV_ELL: MV_ELL; end;` | エラーなし。`declField` |
| `procedure MV_F(MV_ELL); begin MV_ELL end;` | `ERROR` |
| `procedure MV_F(MV_ELL: MV_ELL); begin MV_ELL end;` | エラーなし。`declArg` |

クラス本体と仮引数リストでは、`名前: 型` の形にしないとパースできない。前処理は字句レベルなので文脈を知らない。対策として、最初のパースで `ERROR` の近くにある ellipsis だけを代替の綴り（`__rawpaco_ell__: __rawpaco_ell__`）に差し替えて再パースする。この部分は不確実性が高いので M3 に回し、M1〜M2 は式・引数・文の位置の ellipsis に限定する。

**(5) パターン IR へ変換する。**

パースした木はそのまま保持せず、自前のパターン IR（ノード種別、フィールド名、子の列、葉のテキスト、メタ変数・ellipsis・深い式のフラグ）に変換してから `ts_tree_delete` する。理由は3つある。プレースホルダ識別子をメタ変数ノードに戻す処理と正規化を読み込み時に一度で済ませるため、ラッパーを剥がすため、`TSTree` の寿命管理をルールの寿命から切り離すためである。

`<... e ...>` は前処理で `__rawpaco_deep__(e)` という呼び出しの形に置換し、IR 変換時に「部分式のどこかに e を含む」ノードへ変える。

### 4.3 マッチャ

パターン IR と対象の `TSNode` を再帰的に照合し、成功したら `(開始バイト, 終了バイト, メタ変数束縛)` を返す。

**基本規則。**

- ノード種別とフィールド名が一致し、子の列が一致すれば一致。tree-sitter-pascal ではキーワードも `kBegin` や `kAssign` のような名前付きノードなので、名前付きの子だけを比べれば演算子の違いも区別できる【実測】
- `comment` と `pp`（コンパイラ指令）は対象側の子の列から除外する。これらは文法上の extras で、引数リストの途中にも現れる【実測】
- `ERROR` または `MISSING` を含む部分木には一致させない。ただし下記の `raise;` は例外

**葉の比較。**

- `identifier`: 大文字小文字を区別しない（Pascal の規則）。先頭の `&`（予約語エスケープ）は外して比べる
- `literalString`: テキストの完全一致。`'...'` というパターンは任意の文字列リテラルに一致
- `literalNumber`: テキストを大文字小文字を区別せず比較。`$FF` と `255` を同じとはみなさない（値の正規化はしない）

**メタ変数。**

- パターン中の `identifier` の位置に置かれたメタ変数は、対象側の同じ位置にある任意の名前付きノード1個に一致する。キーワードのノードと extras には一致しない
- 同じメタ変数の2回目以降の出現は、最初に束縛した部分木と**構造的に等しい**ことを要求する。比較は上の葉の規則に従うので、空白・コメント・大文字小文字の違いは無視される
- `$_` は束縛しない

**ellipsis。**

- 子の列の中の ellipsis は 0 個以上の兄弟に一致する。バックトラックで実装する
- 文の並びのパターン（`A; ...; B`）は、`block` / `statements` / `blockTr` の子の列の**部分列**として照合する。先頭と末尾には暗黙の ellipsis がある。HANDOFF.md にあるとおり `begin...end` は `block`、try や repeat の本体は `statements` という別のノード種別なので、3種とも対象にする
- 文の ellipsis の後ろの文を入れ子のブロックの中まで探すか（opengrep の `go_deeper_stmt` 相当）は、opengrep の（おそらくの【未確認】）既定に合わせて**既定で探す**。**決定（#4、2026-11-17）:** ルール5 を踏まえ、入れ子のブロックへ潜って初めて見つかった正の一致は、ルールの重要度より**一段低い重要度**で報告する（`svError` → `svWarning`、`svWarning` → `svInfo`、`svInfo` は `svInfo` のまま）。メッセージには入れ子のブロック内での一致である旨の注記を付ける。否定側の演算子（`pattern-not`、`pattern-not-inside`）では深く探すほど除外が広がり、警告は減る。「深く潜って見つけた」印は、ブール演算子の合成を通して範囲に付けたまま持ち回す。ルールの `options: { go_deeper_stmt: false }` で無効にできる
- **文の並び（M2 で実装、2026-11-19、`PatMatcher.FindSequenceMatches`）。** 実装で決めたこと:
  - 対象は `block`・`statements`・`blockTr` の子。キーワードの子（`begin`、`end` など）、名前なしのトークン、コメントは読み飛ばす。`pp` 指令（条件コンパイルに限らずすべて）、`raise;` の形以外の `ERROR`、`MISSING` は**列を区間に分け**、一致は 1 つの区間の中に収まらなければならない。「ellipsis は条件コンパイル指令をまたがない」より厳しいが（隣り合う項目が `{$I file.inc}` や `{$R-}` をまたぐのも止める）、ルール5 の趣旨に沿う
  - パターンの項目は連続する子に一致し、両端に暗黙の ellipsis がある。開始する文ごとに一致は最大 1 件。先頭に明示した `...` / `$...X` は範囲を区間の最初の文から始め、末尾のものは区間の最後の文まで伸ばす（`pattern-inside: "$X := ...; ..."` がブロックの残りを覆うようにするため）。途中の ellipsis は短い方から試す
  - 入れ子への探索は、直接の照合が失敗したときだけ、**最後の**ellipsis でない項目（その後ろは ellipsis だけ）にだけ使う。その項目は、後ろの兄弟の中に入れ子になった文のノード（`try` の本体、`if` の枝、入れ子の `begin … end`）に一致してよい。この一致には「深く潜った」印が付く。印は 4.4節のとおり合成を通して持ち回す: 積と `pattern-inside` では片方にあれば付き、同じ一致をまとめるときは 1 つでも印の無いものがあれば外れ、アダプタはその範囲で報告する一致がすべて印付きのときだけ重要度を下げる。メッセージに付ける注記は ` (matched inside a nested block)`
  - パターンの字句処理で、行に単独で括弧の外にある `...` / `$...X` には `;` を補う。tree-sitter-pascal は文の位置の ellipsis を `;` なしではパースできないが、opengrep の他言語のルールは普通 `;` を書かないため。`...;` と書いてもよい
  - ellipsis だけから成る並びは、ellipsis 1 個と同じく読み込みエラー

**Pascal 固有の扱い。** いずれも tree-sitter-pascal の木の形に由来し、opengrep なら Generic AST 変換器が吸収している部分である。

| 事象 | 木の形【実測】 | 方針 |
|---|---|---|
| 括弧なしの呼び出し | `Foo;` は `statement` > `identifier`。`Foo();` は `statement` > `exprCall`。`X.Free;` は `statement` > `exprDot` | パターン `Foo(...)` や `$X.Free(...)` は、**文の位置にある**括弧なしの形にも一致させる。式の位置（`Y := Foo`）では変数参照と区別できないので一致させない。対象は引数リストが無いか、引数が ellipsis だけの呼び出しパターンに限り、`Foo($X)` は括弧なしの呼び出しに一致しない。`;` の無い `then` の分岐や `case` の `else` の分岐も `statement` ノードなので、同じく文の位置として扱う【M1 で実測】 |
| 引数なしの `raise;` | `ERROR` > `kRaise`（文法の穴。HANDOFF.md 既知） | パターン側の `raise;` は専用の IR ノードに変換し、対象側の「`kRaise` だけを持つ `ERROR`」に一致させる。この形の `ERROR` は「エラーを含む部分木には一致させない」規則の例外にする。【M1 で実測】この `ERROR` はフィールド名の無い extra で、属する文の並びの中（または属するフィールドの直前の兄弟。`except:` の `statements` の前や、`if C then raise;` の `then` の位置など）に現れる。そのためパターン側・対象側の両方で普通の子として残し、位置も構造として比べる。メタ変数はこれに束縛しない。同じ並びで後ろに文が続く `raise;`（`except raise; Bar; end`）は、次の文をオペランドにした `raise` ノードと `;` だけの `ERROR` になる。これは本物のエラーなので一致させない。`;` の無いパターン `raise` は式のラッパーで `raise` という名前の識別子として読まれ、何にも一致しない |
| 括弧 | `(A)` は `exprParens` | 照合時に透過として扱う（パターン IR では読み込み時に除去し、対象側では照合時に読み飛ばす） |
| 空の引数リスト | `Foo()` には `exprArgs` ノード自体が無い【M1 で実測】 | 子が ellipsis だけのパターンノード（`Foo(...)` の `exprArgs` など）は、対象側に対応する子が無いときも 0 個の列として一致させる。opengrep と同じく `Foo(...)` が `Foo()` に一致する |
| 条件コンパイル | `{$IFDEF A} Foo; {$ELSE} Bar; {$ENDIF}` は両方の枝が同じ列に並ぶ | 文の ellipsis は条件コンパイル指令の `pp` をまたがない |
| `with` 文 | 本体の裸の識別子はレコードのフィールドかもしれない | エンジンでは特別扱いしない。ルール作者が `pattern-not-inside` で除外する。同梱ルールでは必須の確認項目にする（HANDOFF.md で最大の誤検知源と実測済み） |
| マクロ | `{$MACRO ON}` のファイルでは識別子が展開で消える | 同上。ファイル単位の除外条件をルールの `options` で指定できるようにするかは未決 |
| 実装ヘッダの名前 | `procedure TFoo.Bar` の名前は `exprDot` ではなく `genericDot` | 同一視しない。宣言の名前を使用箇所として数えないため |

ファイル全体に対する `ts_node_has_error` の門番は採用しない。`raise;` のせいで、対象になりうるファイルの 61% がエラーありになるという実測がある（HANDOFF.md）。一致した範囲の内側だけを見る。

### 4.4 ブール演算子の合成

各葉は `(範囲, 束縛)` の集合を返し、演算子はその集合を合成する。opengrep と同じ枠組みである。

| 演算子 | 合成 |
|---|---|
| `pattern-either` | 和集合 |
| `patterns` の肯定項 | 範囲の包含関係があり束縛が両立する組だけを残す |
| `pattern-inside` | 肯定側の範囲が inside 側の範囲に含まれ、束縛が両立するものを残す。inside 側の束縛を引き継ぐ |
| `pattern-not-inside` | 上と同じ判定で、該当するものを除く |
| `pattern-not` | 範囲が一致し束縛が両立するものを除く |
| `pattern-regex` | 正規表現の一致範囲を葉として扱う。名前付きグループはメタ変数として束縛する |
| `focus-metavariable` | 報告範囲を、束縛されたノードの範囲に差し替える |

「束縛が両立する」とは、両方に現れるメタ変数がすべて構造的に等しい部分木を指していること。`patterns` に肯定項が1つも無いルールは読み込みエラーにする。

細部（特に `patterns` の中に `pattern-inside` が複数ある場合の評価順、`pattern-either` と束縛の組み合わせ）は opengrep の実装に歴史的な特例がある【ソース確認: `Match_search_mode.ml` のコメント】。M2 で、7.3節の差分テストによって確定させる。

**M2 の論理結合（2026-11-19 実装、`src/Decl/Formula.pas`）。** 以下は暫定の選択で、7.3節の差分テストで opengrep と突き合わせる。

- ルールに書ける式は `pattern`・`patterns`・`pattern-either` のどれか 1 つ。`pattern-not`・`pattern-inside`・`pattern-not-inside` は `patterns` の直下でだけ受け付け、それ以外（ルールの直下、`pattern-either` の中）では読み込みエラーにする。演算子のリストの各要素はキーが 1 つだけのオブジェクト。エラーは位置を添えて出す（例: `"patterns"[1]."pattern-not": ...`）
- `patterns` の中の項は、書かれた順にかかわらず次の順に適用する: 正の項（書かれた順に積を取る）→ 各 `pattern-inside`（その中にある正の一致を残し、束縛を足す）→ 各 `pattern-not-inside` → 各 `pattern-not`。したがって否定の項は `pattern-inside` から受け継いだ束縛を使える
- 正の集合 2 つの積は、どちら側の一致でも、もう一方の両立する一致の範囲の中にあるものを残し、両方の束縛を合わせる（名前が重なるのは両立する組だけなので、内側の一致の束縛を採っても同値なノードになる）
- 「両立する」は、単一ノードの束縛は構造で（同じメタ変数の 2 回目の出現と同じ比較）、範囲の束縛（`$...X`）はソーステキストの完全一致で比べる
- 結果は範囲の順に並べる。範囲も束縛も同じ一致は 1 件にまとめる。範囲が同じで束縛が違うものは評価の間は残し（後の否定の項に効くため）、アダプタが範囲ごとに 1 件だけ報告する
- **正規表現の演算子（M2 で実装、2026-11-19、`src/Decl/DeclRegex.pas`）。** `pattern-regex` は正の項（ルールの直下、`patterns`、`pattern-either` に書ける）。opengrep と同じくファイルの生のテキスト（コメントや文字列も含む）に当て、束縛は無く、長さ 0 の一致は報告しない。`pattern-not-regex`（`patterns` の中だけ）は、範囲がどちら向きに含まれても正の一致を除く。テキストの一致は構文の境界とめったに揃わないため。`metavariable-regex`（`patterns` の中だけ。値は `{"metavariable": "$X", "regex": "..."}`）は `pattern-inside` の後、否定の項の前に適用する。そのメタ変数は同じ `patterns` の他の項で束縛されていなければならず（されていなければ読み込みエラー）、正規表現は束縛のテキストの先頭に固定し、大文字小文字の扱いは #5 に従う（4.5節）。正規表現は PCRE2 と同じく `.` が改行に一致せず、`^` / `$` が行の境目に一致する設定で動かす。名前付きグループは `RegExpr` 自体が受け付けないので、`pattern-regex` はまだメタ変数を束縛しない

### 4.5 メタ変数制約

- `metavariable-regex`: 束縛されたノードの**ソーステキスト**に正規表現を当てる。Pascal の識別子は大文字小文字を区別しないので、ルール作者が `(?i)` を付け忘れると検知漏れになる。**決定（#5、2026-11-19）: 束縛が `identifier` のノード 1 個のときは、既定で大文字小文字を無視する**（opengrep との rawpaco 独自の違い）。それ以外の束縛（文字列リテラル、その他の式、`$...X` の範囲）は区別して照合する。正規表現は束縛のテキストの先頭から一致しなければならない（先頭にだけ固定し、末尾には固定しない）。メタ変数が束縛されていない一致は落とす
- `metavariable-pattern`: 束縛されたノードの部分木を対象に、入れ子の formula を評価する
- `metavariable-comparison`: M4。対象は整数リテラルと文字列リテラルに束縛されたメタ変数、演算は比較・四則・`and` / `or` / `not`・`int()` / `str()` / `len()` 程度に限定し、範囲外の式は読み込みエラーにする

### 4.6 ルールローダ

受け付けるトップレベルは `rules:` の配列。各ルールのキーは `id` / `message` / `severity` / `languages` / `metadata` / `paths` / `options` / `fix` と、2.7節の演算子。

- `languages`: `pascal` を受け付ける。別名（`delphi`、`fpc`）を認めるかは未決。それ以外の言語だけを指定したルールは読み飛ばし、標準エラーに1行で知らせる
- 取り込まない機能のキー（`mode: taint`、`pattern-sources`、`metavariable-type` など）を含むルールは**読み込みエラー**にする。黙って読み飛ばすと「ルールを入れたのに何も検出されない」状態になり、検出されないことを安全と誤読される
- 未知のキーもエラー
- `severity`: 現在の `TSeverity` は `svWarning` と `svError` の2値で、宣言順が `--fail-on` の比較に使われている【ソース確認: `Diagnostics.pas`】。`ERROR` / `HIGH` / `CRITICAL` は `svError`、`WARNING` / `MEDIUM` は `svWarning` に対応させる。`INFO` / `LOW` の受け皿が無いので、**決定（#6、2026-11-17）: `svInfo` を `svWarning` の前に追加する**（`--fail-on` に `info` が増える）。入れ子のブロック内の一致を一段下げる先として M2 で既に必要になる（#4、4.3節）

**M1 の JSON ローダ（2026-11-19 実装、`src/Decl/RuleFile.pas`）。** JSON の形は opengrep の YAML をそのまま JSON にしたもの: `{"rules": [{"id": ..., "message": ..., "severity": ..., "languages": [...], "pattern": ...}]}`。実装の中で決めたこと:

- M1 で受け付けるルールのキー: `id`、`message`、`severity`、`languages`、`pattern`、`metadata`（オブジェクト。中身は見ない）、`options`（`pascal_hex_dollar` と `go_deeper_stmt`。どちらも真偽値で、他のオプションはエラー）。最上位のキーは `rules` だけ
- それ以外のキーはすべて読み込みエラーで、メッセージを 3 種類に分ける: 後のマイルストーンで実装する予定のキー（`patterns`、`pattern-either`、`pattern-regex`、`metavariable-*`、`focus-metavariable`、`paths`、`fix` など）は「まだ未対応」、対象外の機能（`mode`、`pattern-sources` などの taint のキー、`metavariable-type`、`join`、`extract` など）は「対象外」、それ以外は「未知のキー」
- `id` は空でなく、英数字・`_`・`-`・`.` だけから成ること（`--only` / `--exclude` のカンマ区切りと衝突させないため）。ID の重複は、同じファイルの中でも、読み込み済みのルールとの間でもエラー
- `languages` は空でない文字列の配列。文字列 `pascal`（完全一致）を含まないルールは通知を出して飛ばす（別名は未決 #10 のまま）
- `severity` は opengrep と同じく大文字小文字を区別する。M1 では `INFO` / `LOW` を `svWarning` に寄せずに読み込みエラーにした（ルール作者の意図より重く報告すると `--fail-on=warning` のビルドを落としうるため）。**M2（2026-11-19）で `svInfo` を `svWarning` の前に追加した**。`INFO` / `LOW` はこれに対応させ、`--fail-on=info` を受け付ける。text / json 形式は `info`、github 形式は `::notice` と出す（GitHub Actions に `info` のコマンドは無い）。組み込みのルールは使わない
- 文の並びにコンパイルされる `pattern` は M2 まで読み込みエラー。M1 の照合器は文の並びに何も一致させず、空の結果が「安全」と読まれてしまうため（文の並びを照合するようになった M2 で解除）
- 読み込みはファイル単位で全か無か。エラーの形は `<ファイル>: rules[<i>] (id "<id>"): <理由>`
- 開発者向けオプション `--dump-rules=FILE` で、読み込んだルールとパターン IR を表示する。ゴールデンテストは `tests/decl/load/`

**YAML をどう読むか。** 候補は4つある。

| 案 | 内容 | 評価 |
|---|---|---|
| 1 | FPC の `fcl-yaml`（`fpyaml.parser` ほか） | freepascal.org の daily（trunk）ドキュメントに存在を確認した【実測: Web 検索】。CI が使う FPC 3.2.2 には含まれていない【実測（M0）: 3.2.2 のインストール済みユニットに無く、あるのは `fcl-json/json2yaml` のみ。3.2.2 世代の FCL リファレンスの索引にも無い】。バグ報告もある。**現時点では使えない** |
| 2 | libyaml（C、MIT）を `vendor/` に入れて cdecl で呼ぶ | 既存の tree-sitter と同じ方式。ルール1 により `yaml.h` との照合が必須。Windows のリンクで再び苦労するリスクがある |
| 3 | YAML のサブセットを FPC で自作する | ブロック形式のマッピングとシーケンス、プレーン・引用符付きスカラー、`\|` と `>` のブロックスカラー、コメントに対応。アンカー、タグ、複雑なフロー形式は**明示的にエラー**にする。500〜800 行の見込み |
| 4 | JSON 形式のルールファイルを `fpjson` で読む | `fpjson` は `RawpacoConfig.pas` で既に使っている依存なので、追加の依存が無い。複数行のパターンが書きにくい |

推奨は「**M1 は案4（JSON）で始め、M3 で案3（自作サブセット）を足す**」。エンジンの検証を YAML パーサの作業から切り離せる。JSON を選ぶ時点で `fcl-json` を Windows CI のユニット検索パスで見つけられることは既に解決済みである（HANDOFF.md）。

いずれの案でも、使う FPC の標準ユニット・関数は CLAUDE.md ルール1 に従い、実装前に freepascal.org のドキュメントで存在を確認する。本書の時点で確認が済んでいるのは「`fcl-yaml` が trunk のドキュメントに載っている」ことだけである。

**正規表現。** opengrep は PCRE2 を使う【ソース確認: `libs/pcre2`】。候補は FPC 同梱の `RegExpr` ユニット（`TRegExpr`）か、PCRE2 を `vendor/` に入れるかの2つ。前者は追加の C 依存が無いが方言が違う。

M0 の結果（2026-11-17）。freepascal.org の 3.2.2 向け FCL リファレンスには `RegExpr` が載っておらず、wiki は停止中だったため、ルール1 の意味では **freepascal.org で未確認**である。以下はインストール済みのユニット（`regexpr.ppu`、`TRegExpr.VersionMajor/Minor` = 0.987）と検証プログラムによる【実測】。

| 構文 | 結果 |
|---|---|
| `(?i)`、非貪欲 `*?`、`\b`、`^` / `$`、`(?:...)`、`{n,}`、後方参照 `\1` | 動く。既定は大文字小文字を区別 |
| 先読み・後読み `(?=` `(?!` `(?<=` `(?<!`、名前付きグループ `(?P<n>` `(?<n>` `(?'n'`、アトミック `(?>` | コンパイルエラー（unrecognized modifier） |
| 所有的量指定子 `a++`、Unicode プロパティ `\p{L}` | コンパイルエラー |
| POSIX クラス `[[:alpha:]]` | **エラーにならず黙って誤解釈**される（`12abc` に一致しない） |
| UTF-8 | バイト単位。`.`・`\w`・`[é]` はいずれも 1 文字ではなく 1 バイトに一致する |

**決定（#8、2026-11-17）: `RegExpr` で始める。** 非対応の構文を含む正規表現は読み込みエラーにする。POSIX クラスのようにコンパイルエラーにならない非対応構文があるので、`ERegExpr` 任せにせずローダ側で独自に事前検査する。正規表現を使うのは M2 からなので、実際のルールに先読み等が必要かは M2 着手時に再評価する（代替: 新しい Pascal 版 `TRegExpr` の vendoring、または PCRE2）。

### 4.7 既存のルール基盤との統合

- **登録**: 宣言的ルール1本につき `IRawpacoRule` を実装したアダプタを1個作り、`RegisterRule` する。`InterestedNodeTypes` は `root` のみとし、`Check` の中でファイル全体を自己完結で評価する。これは RAWPACO-DEPR-001 が採った方式（インスタンスにファイルをまたぐ状態を持たせない）と同じである
- **`--only` / `--exclude`**: `AllRuleIds` が登録済みルールから ID を集める作りなので、ルールファイルの読み込みを `SetRuleFilter` より前に行えばそのまま効く。ID がネイティブルールと重複したら読み込みエラー
- **CLI**: `--rules=<ファイルまたはディレクトリ>` を追加（複数指定可）。プロジェクトに固定するものは設定ファイル、という既存の層分けに従い `rawpaco.json` に `rulePaths` を足すかは未決
  - **M1 で実装（2026-11-19、`src/Decl/DeclRule.pas`）。** ディレクトリを渡すと直下の `*.json` を読み、Windows と Linux で順序が揃うよう `CompareStr` で名前順に並べる。再帰はしない。存在しないパスと、`*.json` が 1 つも無いディレクトリはエラー（終了コード 2）。宣言的ルールの ID が、大文字小文字を無視してネイティブのルールの ID と一致したらエラー（大文字小文字だけが違う ID は `--only` の指定や出力で紛らわしいため）。ルールは `--only` / `--exclude` の検査より前に登録するので、これらのオプションに宣言的ルールの ID を書ける。他言語のルールを飛ばした通知は標準エラーに出す。`rawpaco.json` にはまだキーを足さない（#9 は未決のまま）。lint 全体を通したゴールデンテストは `tests/decl/cli/`
- **診断**: `TDiagnostic` は開始位置しか持たない【ソース確認】。SARIF の region、`focus-metavariable`、autofix のために終了位置を追加し、`TLintContext` に範囲で報告する口を足す
- **メッセージ**: `message` 中の `$X` を束縛テキストで置換する。**M1 で実装（2026-11-19、`src/Decl/MsgInterp.pas`）。** 参照の字句はパターンと同じ規則（`$` + 英大文字・数字・`_`、最長一致）と `$...X`。`$X` には単一ノードの束縛だけ、`$...X` には範囲の束縛だけを入れる。束縛されていない参照（`$_` を含む）は書かれたまま残し、読み込み時に警告を出すがエラーにはしない（M2 の `pattern-either` では片方の枝でだけ束縛される名前が正当にありうるため）。束縛テキストの空白・改行の並びは空白 1 個にまとめる（複数行の束縛で、1 診断 1 行の text / github 形式が壊れないように）
- **抑制**: 既存の `// rawpaco:ignore <RuleId>` がそのまま効く。`nosemgrep` コメントを別名として認めるかは未決
- **出力**: `--format=sarif` を追加。SARIF 2.1.0 を `fpjson` で組み立てる
- **TSBindings**: 追加が必要になる見込みの関数は `ts_node_is_named`（`api.h` 511 行）、`ts_node_is_missing`（517 行）、`ts_node_is_extra`（523 行）、`ts_node_eq`（683 行）、`ts_node_symbol`（451 行）。行番号は vendoring 済みヘッダで位置を確認したもので、宣言を書く時点でシグネチャを照合する（ルール1）
- **ネイティブルール**: 置き換えない。ただし DEFENSE-001（空の except）や SEC-001（SQL 文字列連結）は宣言的ルールでも書けるはずなので、同じ検出を両方式で書いて結果を突き合わせることをエンジンの検証に使う（7章）

---

## 5. CLAUDE.md の各ルールとの整合

| ルール | 推奨案 (d) での扱い |
|---|---|
| 1. RTL・C ライブラリの検証 | 新規の C 依存を増やさない構成（JSON → 自作 YAML、`RegExpr`）を第一候補にした。`TSBindings` の追加関数は `api.h` と照合。`RegExpr` と `fcl-yaml` は freepascal.org で確認してから使う |
| 2. tree-sitter-pascal の固定 | 文法を改変しない。パターンは前処理とラッパーで v0.10.2 のまま通す。ただしパターンの木の形が文法バージョンに依存するので、文法を更新するとユーザーのルールが黙って壊れうる。更新時の確認手順に「パターンコンパイルのゴールデンテスト」を足す |
| 3. positive / negative 両方 | エンジンの機能（演算子、メタ変数、ellipsis の各位置）ごとに両方のサンプルを置く。同梱する宣言的ルールにも同じ規則を適用 |
| 4. 自己 lint | 同梱する宣言的ルールを `make selflint` の対象に含める |
| 5. false positive 回避 | 4.3節の Pascal 固有の扱いはすべて「疑わしきは一致させない」側に倒した。取り込まない機能を含むルールは読み飛ばさずエラーにする |
| 6. Oxygene 対象外 | `languages` は Pascal のみ |
| 7. Windows / Linux | 新規ユニットを両方の CI のビルドに追加。CRLF、`paths` のパス区切りを両環境でテスト |
| 8. コメント方針 | 前処理の置換規則、ラッパーの試行順、Pascal 固有の扱いは「なぜ」のコメントが必須の箇所 |

ルール5 との緊張関係が1つある。宣言的ルール層を入れると、ルールの品質がエンジンの外（YAML を書く人）に移る。ネイティブルールは fpc-source 全体（約 4,900 ファイル）で誤検知を実測してから入れてきたが、利用者が書いたルールにその保証は無い。同梱ルールとユーザールールを出力上で区別できるようにしておく。

---

## 6. 段階的な実装ロードマップ

規模は FPC の行数の概算で、精度は低い。

| マイルストーン | スコープ | 規模の目安 | 完了条件 |
|---|---|---|---|
| **M0** 事前確認 | `RegExpr` の機能を freepascal.org と実機で確認。10章の未決事項のうち着手前に必要なものを決める | 小 | 判断結果を HANDOFF.md に記録 |
| **M1** パターン中核 | 前処理（メタ変数、16 進の曖昧性エラー、式・引数・文の位置の ellipsis）、ラッパー、パターン IR、マッチャ（メタ変数の単一化、子の列の ellipsis、葉の比較、括弧なし呼び出し、`raise;`）。JSON ルールファイル、`pattern` 単体、`--rules`、メッセージ補間 | 1,500〜2,000 行 | DEFENSE-001 相当を宣言的ルールで書き、既存のサンプルで同じ結果になる |
| **M2** 合成 | `patterns` / `pattern-either` / `pattern-not` / `pattern-inside` / `pattern-not-inside`、範囲演算、文の並びのパターン、`pattern-regex` / `pattern-not-regex` / `metavariable-regex`、`focus-metavariable`、診断の終了位置、`svInfo`（入れ子のブロック内の一致を一段下げる先） | 1,000〜1,500 行 | 7.3節の差分テストが通る。fpc-source 全体でクラッシュなし |
| **M3** 形式と範囲の拡張 | YAML サブセットのローダ、`metavariable-pattern`、宣言レベルのパターンと位置依存の ellipsis、`<... e ...>`、`$...ARGS`、`paths`、`options` のサブセット、SARIF 出力 | 1,500〜2,000 行 | ルール作者向けドキュメントと互換性一覧を公開できる状態 |
| **M4** 周辺 | `metavariable-comparison`（限定版）、`fix:` / `fix-regex` と `--fix`（既定は提案のみ）、ルールのテスト用注釈（`// ruleid:` / `// ok:`）、必要なら事前フィルタによる高速化 | 1,000〜1,500 行 | 同梱ルールを数本追加し、fpc-source で誤検知を実測 |
| 対象外 | taint、join、ファイル間、型、定数伝播、SCA、extract、generic モード | — | — |

合計で 5,000〜7,000 行。現在の rawpaco 全体（約 5,800 行）と同じかそれ以上の規模になる。M1 と M2 を終えた時点で「続ける価値があるか」を判断できるよう、各マイルストーンは単独で動く状態で区切ってある。

---

## 7. テスト戦略

### 7.1 エンジンのテスト

- `tests/decl/<機能名>/` に、ルールファイル、positive（一致してはいけない `.pas`）、negative（一致すべき `.pas`）を置く。既存の `tests/run_tests.sh` の流儀（終了コードと出力の両方を見る）に合わせる
- パターンコンパイルのゴールデンテスト: パターン文字列からパターン IR のダンプを出し、期待値と比べる。tree-sitter-pascal を更新したときの影響検出に使う（ルール2）
- 読み込みエラーのテスト: パースできないパターン、曖昧な `$ABC`、未対応キー、肯定項の無い `patterns`、ID の重複が、いずれも終了コード 2 になること
- Pascal 固有の扱い（4.3節の表）は、1行ごとに positive と negative を用意する
- CLI からまだ届かず tree-sitter に依存しない部品（パターンの前処理 `src/Decl/PatLexer.pas` など）の単体テスト: 失敗時に 0 以外で終了する小さなプログラム `tests/unit/Test<ユニット名>.lpr` を置き、`make test`（`unittest` ターゲット）と Windows CI ジョブの専用ステップで実行する

### 7.2 実コードでの検証

- fpc-source 全体に対して、クラッシュしないこと、実行時間、検出件数を測る。既存ルールで続けてきた実測の方法をそのまま使う
- 同じ検出をネイティブルールと宣言的ルールの両方で書き（DEFENSE-001、DEFENSE-002、SEC-001）、fpc-source 上で結果を突き合わせる。差分はエンジンのバグか、パターン言語の表現力の限界のどちらかなので、どちらであるかを記録する

### 7.3 opengrep との差分テスト（限定的）

opengrep は Pascal の構文パターンを実行できないので、パターン照合の互換性は比べられない。比べられるのは**合成の意味論**だけである。葉を `pattern-regex` だけにしたルール（`patterns`、`pattern-either`、`pattern-not`、`pattern-inside` の組み合わせ）は言語に依存しないので、同じルールと同じ `.pas` ファイルを opengrep と rawpaco の両方に通して範囲を比較できる。

これは Linux の CI に任意のジョブとして置き、opengrep のバージョンを固定する。正規表現の方言差が結果に混ざらないよう、テストで使う正規表現は単純なものに限る。opengrep が `languages: [regex]` のルールで合成演算子をどこまで受け付けるかは【未確認】で、M2 の最初に確かめる。

### 7.4 CI

Linux と Windows の両方でビルドとテストを実行する（ルール7）。Windows は 32bit ビルドなので、バイトオフセットや長さを扱う箇所で `LongWord` のアンダーフロー（`ASTWalker.pas` のコメントにある既知の罠）を踏まないことを確認する。

---

## 8. tree-sitter-pascal の制約と回避策のまとめ

| 制約 | 回避策 | 残るリスク |
|---|---|---|
| コード片を単独でパースできない | `begin ... end` と代入のラッパー（4.2節） | ラッパーの外では現れない構文（型式、クラスメンバ単体、`uses` の一部）はラッパーの種類を増やす必要がある |
| `$X` が 16 進リテラルと衝突 | 前処理で置換。曖昧な名前はエラー | opengrep と非互換。既存ルールの移植時に改名が要る |
| `...` がパースできない | 位置に応じたプレースホルダ | 位置の判定が再パースによる試行になる。組み合わせが増えると読み込みが遅くなる |
| `raise;` が `ERROR` になる | 専用の IR ノードと例外規則 | 文法が更新されて正しくパースされるようになると、この特例を外す必要がある |
| 括弧なし呼び出しが呼び出しノードにならない | 文の位置に限って同一視 | 式の位置の括弧なし関数呼び出しは検出できない（検知漏れ側） |
| `block` と `statements` が別のノード種別 | 両方（と `blockTr`）を文の並びとして扱う | 文法更新で種別が増えると静かに一致しなくなる。ゴールデンテストで検出 |
| 条件コンパイルの両枝が同じ木に並ぶ | 文の ellipsis は指令をまたがない | 指令の内側で完結するパターンは、無効な枝にも一致する |
| マクロ、`{$I}` によるインクルードは展開されない | エンジンでは対処しない | ルール作者の責任になる |
| 型情報・シンボル表が無い | 型と名前解決に依存する機能を取り込まない | `with` 文の内側など、名前の指す先が変わる箇所での誤検知 |

---

## 9. リスク

1. **「互換」という期待とのずれ。** 最大のリスク。構文パターンの挙動を opengrep と比べる手段が無く、Pascal 固有の扱いと `$ABC` の規則で意図的に非互換にしている箇所もある。ドキュメントでは「opengrep のルール形式に基づく Pascal 方言」と表現し、互換性一覧（対応・非対応・挙動が違う点）を最初から用意する。
2. **投資対効果。** rawpaco 本体と同規模のコードを足して得られるのは「YAML でルールが書ける」ことで、Pascal 向けの既存ルール資産は無い。M1〜M2 の後に続行を判断する区切りを置いた理由はこれである。
3. **誤検知の責任の所在。** 5章の末尾に書いたとおり、ユーザールールの品質は保証できない。
4. **文法バージョンへの依存。** ユーザーのルールがノード種別の形に間接的に依存する。文法を更新したときにルールが黙って一致しなくなる。
5. **位置依存の ellipsis（4.2節 (4)）。** 実測は少数の例だけで、宣言レベルのパターン全般に通用するかは分からない。M3 で難航したら、宣言レベルのパターンを非対応にするか、案(e) のクエリを併用する。
6. **正規表現の方言差。** `RegExpr` の機能が足りなければ PCRE2 の vendoring が必要になり、Windows のリンク問題が再燃しうる。
7. **性能。** 素朴な実装は「ルール数 × 葉の数 × ノード数」の照合になる。同梱ルールが少ないうちは問題にならない見込みだが、実測していない。
8. **ライセンスの運用。** 実装者が opengrep のソースを見ながら書くと、派生物の疑いが生じる。3章の運用ルールを守る必要がある。

---

## 10. 未決事項（オーナー判断が必要なもの）

1. ~~**方針そのもの**~~: **決着（2026-11-16）**。推奨案 (d) で進める
2. ~~**本書の言語と配置**~~: **決着（2026-11-16）**。規約に揃え、英語版 `docs/OPENGREP_RULE_ENGINE_DESIGN.md` を正、本書を `_jp` とした
3. ~~**`$ABC` 形式のメタ変数**~~: **決着（2026-11-17）**。既定は読み込みエラー。ルールごとの `options: { pascal_hex_dollar: true }` で 16 進リテラル扱い＋警告（4.2節）
4. ~~**`go_deeper_stmt` の既定**~~: **決着（2026-11-17）**。既定で有効。入れ子のブロック内でだけ見つかった一致は重要度を一段下げて報告し、`options: { go_deeper_stmt: false }` で無効化できる（4.3節）
5. ~~**識別子に対する `metavariable-regex`**~~: **決着（2026-11-19）**。束縛が識別子 1 個のノードのときは、既定で大文字小文字を無視する（opengrep との意図的な違い）。それ以外の束縛（文字列リテラル、式、`$...X` の範囲）は区別する（4.5節）
6. ~~**`severity`**~~: **決着（2026-11-17）**。`svInfo` を追加する（#4 により M2 から必要）
7. **YAML**: JSON 先行＋自作サブセットでよいか。libyaml の vendoring を選ぶか
8. ~~**正規表現**~~: **決着（2026-11-17）**。`RegExpr` で始め、非対応構文は読み込みエラー。M2 着手時に再評価する（4.6節）
9. **ルールの指定方法**: CLI の `--rules` のみか、`rawpaco.json` にもキーを足すか
10. **`languages` の別名**、**`nosemgrep` コメントの受け入れ**
11. **同梱する宣言的ルール**: 既存のネイティブルールの一部を宣言的ルールへ移すか、検証用の二重実装に留めるか
12. **taint の簡易版**: rawpaco 独自機能として将来検討するか。土台になりうるもの（自前の CFG とデータフロー解析エンジン）の設計を [DATAFLOW_ENGINE_DESIGN_jp.md](DATAFLOW_ENGINE_DESIGN_jp.md) の 11章と未決事項10 に書いた。本項目は未決のまま

---

## 付録: この調査で実行したこと

- rawpaco: `CLAUDE.md`、`HANDOFF.md`、`src/` の主要ユニット、`Makefile`、CI 設定、`LICENSE` を読んだ。`fpc` がこの環境に無いため **rawpaco 本体のビルドとテストは実行していない**
- tree-sitter-pascal: `vendor/` の `lib.c` と `parser.c` を gcc でビルドした小さな検証プログラム（scratchpad 上、リポジトリには置いていない）で、約 60 個のコード片のパース結果を確認した。4.2節と 4.3節の【実測】はこれによる
- opengrep: 公開リポジトリを取得し、ライセンス、対応言語の一覧、各ディレクトリの行数、`Rule.ml` / `Xpattern.ml` / `Xlang.ml` / `Range_with_metavars.ml` と、`Match_search_mode.ml` / `Generic_vs_generic.ml` / `Parse_rule.ml` の該当箇所を確認した。**opengrep のビルドと実行はしていない**。挙動についての記述はソースの読解と既知の知識による
- FPC の `fcl-yaml`: Web 検索で freepascal.org の daily ドキュメントに載っていることを確認した。FPC 3.2.2 に含まれないこと、`RegExpr` の機能範囲は設計時点では確認しておらず、M0 で確認した（4.6節）
