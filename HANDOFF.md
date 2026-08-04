# HANDOFF.md

このファイルはセッション間の引き継ぎ用です。決着した論点は都度削除し、git historyに委ねてください（詳細な運用ルールはCLAUDE.mdを参照）。

## ドキュメントの言語について

`docs/RULE_ENGINE_DESIGN.md`・`docs/SYSTEM_FLOW.md`・`docs/flows/*.md` は英語版が正（canonical）。日本語版はファイル名に`_jp`を付けた別ファイル（例: `docs/RULE_ENGINE_DESIGN_jp.md`）として参照用に残している。内容を更新する際は英語版を先に直し、日本語版は追従（または既に古いことが分かる形でそのまま）とする。新規にこの種のドキュメントを追加する場合も同じ命名規約（英語が無印、日本語が`_jp`）に揃えること。本HANDOFF.md自体・CLAUDE.md・README.mdはこの対象外（README.mdは1ファイル内でJP/EN併記、HANDOFF.mdは元々日本語のみ）。

## 実装済みルール一覧

| ID | 内容 | 状態 | 備考 |
|---|---|---|---|
| RAWPACO-DEFENSE-001 | 空のexceptハンドラ(例外の握りつぶし)検知 | 実装済み | `src/Rules/RuleDefense001.pas`。設計書P1。positive 3件/negative 4件、`make test`で検証 |
| RAWPACO-SEC-001 | SQL文字列連結(SQLインジェクションの疑い)検知 | 実装済み | `src/Rules/RuleSec001.pas`。設計書P2。positive 3件/negative 2件。片方だけがSQLキーワードを含むliteralStringで、もう片方が非リテラルの場合のみ検知(両方リテラル/両方非リテラルは対象外) |
| RAWPACO-SEC-002 | シークレットらしき文字列のハードコード検知 | 実装済み | `src/Rules/RuleSec002.pas`。設計書P3。positive 4件/negative 3件。`identifier := literalString`の単純代入と`declVar`/`declConst`の初期値付き宣言が対象。識別子名は接尾辞一致(単純部分一致だと`TokenList`等を誤検知するため)、値はプレースホルダらしき部分一致で除外 |
| RAWPACO-DEPR-001 | 自己矛盾する非推奨API使用(同一ファイル内)検知 | 実装済み | `src/Rules/RuleDepr001.pas`。設計書P4。positive 3件/negative 2件。`deprecated`属性付き`declProc`の名前を集め、同一ファイル内の`exprCall`(括弧付き呼び出し)・裸の識別子文(括弧なし呼び出し)と照合。`Obj.Method`のようなクラスメソッド呼び出しは対象外 |
| RAWPACO-DEPR-002 | FPC RTL/FCLの`deprecated`シンボル使用検知 | 実装済み | `src/Rules/RuleDepr002.pas`。設計書P6。positive 5件/negative 3件。`data/fpc-rtl-symbols.txt`(静的データ)を`src/FPCSymbols.pas`が読む。検知対象は「ユニットレベルで公開されているdeprecatedシンボル」29件(`SysUtils.DecimalSeparator`等の書式グローバル変数群、`SysUtils.GetTickCount`等)。fpc-source全体(4894ファイル)で誤検知ゼロを実測 |
| RAWPACO-HALLUC-001 | FPC RTL/FCLに実在しない識別子(hallucination)検知 | 実装済み | `src/Rules/RuleHalluc001.pas`。設計書P7。positive 4件/negative 3件。DEPR-002とデータを共有。判定A=ユニット修飾された参照(`Math.Clamp`等)、判定B=修飾なし呼び出し(usesが全て既知ユニットの場合のみ)。fpc-source全体(4894ファイル)で誤検知ゼロを実測 |
| RAWPACO-STYLE-001 | 命名規則チェック(設定ファイルベース) | 実装済み | `src/Rules/RuleStyle001.pas` + `src/RawpacoConfig.pas`。設計書P5。positive 3件/negative 3件 + `tests/config/`の設定4ケース。設定は`rawpaco.json`(JSON/fcl-json)。既定は型名`T`(例外クラス`E`も許可)・インターフェース`I`・ポインタ型`P`・classのprivate/protectedフィールド`F`のみ |
| RAWPACO-DEFENSE-002 | 生成直後の無意味なnilチェック検知 | 実装済み | `src/Rules/RuleDefense002.pas`。設計書P8。positive 3件/negative 3件。`Obj := <何か>.Create`(括弧の有無両対応)の直後(同一`block`/`statements`内で隣接する次の文)が`if`/`ifElse`で`Assigned(Obj)`をチェックしている場合のみ検知 |
| RAWPACO-STYLE-002 | 同一ファイル内のエラーハンドリング不統一(近似) | 実装済み | `src/Rules/RuleStyle002.pas`。設計書P9。positive 5件/negative 3件。固定リストの失敗しうるAPI(`AssignFile`/`CloseFile`/`Reset`/`Rewrite`/`BlockRead`/`BlockWrite` と、`uses SysUtils`がある場合のみ`StrToInt`系8種)が、同一ファイル内でtry-except配下と素通しの両方に現れる場合、素通し側を報告。fpc-source全体(4894ファイル)で誤検知ゼロを実測 |

## 見送ったルール（検討済み・意図的に未実装）

- (該当なし)

## tree-sitter-pascal 文法カバレッジの既知の穴

- `docs/RULE_ENGINE_DESIGN.md`のP1設計時点での想定（`exceptionHandler`/`exceptionElse`がexcept節全体を表すノードであるかのような記述）は誤りだった。実際はtry/except/finally全体が単一ノード種別`try`であり、`except`フィールド(multiple:true)に`kExcept`トークンと`statements`/`exceptionHandler`/`exceptionElse`が並ぶ構造。`vendor/tree-sitter-pascal/src/node-types.json`とgrammar.jsで直接確認する必要がある(ドキュメントの想定を鵜呑みにしない)。詳細は`src/Rules/RuleDefense001.pas`冒頭コメント参照。
- P2実装時に確認: 二項式は`exprBinary`(フィールドlhs/operator/rhs)、`+`演算子はoperatorフィールドの子`kAdd`(無名の`'+'`トークンではない)。文字列リテラルは`literalString`で、`ts_node_start_byte`/`end_byte`で切り出したテキストは前後の引用符を含む(値だけを返すフィールドは無い)。詳細は`src/Rules/RuleSec001.pas`冒頭コメント参照。
- P3実装時に確認: `declVar`/`declConst`の`defaultValue`フィールドの中身(`defaultValue`ノード)自体はフィールドを持たず、`kEq`トークンと初期値式が位置的に並ぶだけ。フィールド名検索ではなく「`kEq`以外の子」を位置的に拾う必要がある。手続き引数の`var`宣言は`declVar`ではなく別ノード種別`declArg`。詳細は`src/Rules/RuleSec002.pas`冒頭コメント参照。
- RAWPACO-SEC-002の既知のスコープ外(次の拡張候補): `Obj.Password := 'x'`のような`exprDot`経由のプロパティ・フィールド代入は検知しない。実務では単純な`identifier := literalString`より一般的な可能性すらあるパターンだが、末端の識別子名を取り出すロジックが別途必要で第一段のスコープを超えるため見送った。
- P4実装時に確認: 手続き・関数宣言は`declProc`(procedure/function/constructor/destructor共通)。括弧付き呼び出し`Foo()`は`exprCall`(フィールド`entity`)になるが、括弧なし呼び出し`Foo;`(引数なし手続きのPascal的な書き方)は`exprCall`にならず、`statement`ノードが唯一の子として直接`identifier`を持つだけの形になる。両方を見ないと呼び出しを取りこぼす。詳細は`src/Rules/RuleDepr001.pas`冒頭コメント参照。
- P6実装時に確認: `A.B`は`exprDot`(フィールド`lhs`/`operator`/`rhs`)だが、`procedure TFoo.Bar;`のような実装ヘッダの名前は`exprDot`ではなく**`genericDot`**という別ノード種別になる（宣言名なので使用箇所として数えてはいけない）。`uses`節は`declUses`で各ユニットは`moduleName`ノード。`declVar`/`declField`は`A, B: Integer;`のように`name`フィールドを複数持ちうる。クラス/レコード/オブジェクトはいずれも`declClass`(先頭の子トークンが`kClass`/`kRecord`/`kObject`で区別)、インターフェースは`declIntf`、ヘルパは`declHelper`。可視性は`declSection`配下の`kPrivate`/`kProtected`/`kPublic`/`kPublished`(+`kStrict`)。`class var`はクラス内でも`declVars`/`declVar`になり`declField`にはならない。詳細は`src/Rules/RuleDepr002.pas`冒頭コメント参照。
- P6実装時の実測知見（誤検知対策）: `with Rec do ... end` の本体では裸の識別子がレコードのフィールドを指すため、型解決なしでは RTL のグローバル変数と区別できない。fpc-source 全体(4894ファイル)に当てたところ、`with FormatSettings do begin DecimalSeparator := '.'; ... end` という典型的（かつ推奨される）書き方が誤検知の最大要因（91件中58件）だった。`with`の`body`フィールド配下は走査しないことで解消し、残り33件は全て真陽性であることを目視確認済み。
- P5実装時の実測知見: fpc-source 全体(4894ファイル)に既定設定で当てると 25254 件出るが、内訳は `rtl/java/jdk15.pas`(4192件)・`rtl/android/jvm/androidr14.pas`(2408件)・`packages/winunits-*`・`packages/univint` といった **JVM バインディングや C ヘッダの機械的移植**に集中しており、誤検知ではなく本当に Pascal の命名慣習に従っていないコードである。手書きの `fcl-base`/`fcl-json`/`rtl-objpas`/`rtl-generics` に限ると 105 件で、その大半は `fBuffer` のような小文字始まりの非公開フィールド（大文字小文字を区別する設計判断によるもの。`docs/CONFIG.md` に `["F", "f"]` と書く回避策を記載済み）。
- P5(命名規則)向けの事前調査で確認したノード種別: 型宣言は`declTypes` > `declType`(フィールド`name`/`type`)。`name`は通常`identifier`だが、**ジェネリック型では`genericTpl`**(フィールド`entity`=実際の型名、`args`>`genericArg`>`name`=型引数)になる。`type`側は`declClass`(class/object/recordが全部これ。先頭の子トークン`kClass`/`kObject`/`kRecord`で区別)、`declIntf`(interface)、`declHelper`(class helper/record helper)、`type` > `declEnum`(列挙)、`type` > `typeref` > `typerefPtr`(`^T`のポインタ型)。クラス/レコードのフィールドは`declField`(フィールド`name`は複数持ちうる)、可視性は親の`declSection`の`kPrivate`/`kProtected`/`kPublic`/`kPublished`(+`kStrict`)。`class var`は`declVars`/`declVar`になる。
- P7実装時に確認: `root`の直下は`unit`/`program`/`library`のいずれか、または（`{$i}`で他ファイルに取り込まれる前提の断片の場合）`declTypes`/`declVars`等が直接並ぶ形になる。`inherited Go;`は`exprCall`ではなく`inherited`ノード(`kInherited` + `identifier`)。`ts_node_has_error`(api.h 533行目)で構文エラーの有無を判定できる。
- P7実装時の実測知見（誤検知対策）: fpc-source全体に当てた初版で190件の誤検知が出た。内訳と対処は (1) 175件が`{$MACRO ON}` + `{$define Rsc := }`によるマクロ展開（tree-sitterは展開しないので消える識別子を「実在しない」と誤認）→ `{$MACRO`を含むファイルでは判定Bを無効化、(2) `uses`が1つも無いファイル（`{$i}`で組み立てられるRTL内部ユニットやinclude断片）→ 「usesが1つ以上あり全て既知」を判定Bの前提条件に、(3) `AssignFile`/`CloseFile`が見つからない → これらは`system`ではなく`objpas`ユニット（objfpc/delphiモードで暗黙にuses）にあるため、`objpas`をデータ生成対象に追加。対処後は誤検知ゼロ。
- **P9実装時に確認（重要な文法の穴）**: 引数なしの再送出 `raise;` を tree-sitter-pascal v0.10.2 は**構文として受け付けない**。`raise E.Create(..);`（引数あり）は `raise` ノード（フィールド `exception`）になるが、`raise;` は `ERROR` ノード（子に `kRaise`）になる。影響は2つある。
  - (1) `raise;` を含む部分木を探すコードは `raise` ノード種別だけを見ていると取りこぼす。`kRaise` トークン自体を探す必要がある。
  - (2) `raise;` は Pascal でごく普通の書き方なので、`ts_node_has_error` によるファイル単位の門番（RAWPACO-HALLUC-001 が採用している方式）を入れると実質的にルールが無効化される。実測では、本ルールの対象APIと `except` の両方を含む fpc-source の182ファイルのうち **111ファイル(61%)** が `ts_node_has_error` で真になった。この `ERROR` ノードは文の位置に局所的に現れるだけで try/except/finally のフィールド構造は保たれる（プローブで確認済み）ため、RAWPACO-STYLE-002 では門番を採用しないことにした。
- P9実装時の実測知見（誤検知対策）: 最大の誤検知要因は `try ... except FreeAndNil(Result); Raise; end;` という「失敗したら後始末して呼び出し元へ投げ直す」定型だった。これを「try-exceptで保護されている」と数えると、同じAPIを素直に呼んでいる他の箇所が軒並み未保護として報告される（`packages/fcl-db/src/sql/fpsqlparser.pas` だけで12件）。対策として、except節の部分木に `kRaise` があるtryは保護に数えないことにし、fpc-source全体で検知ゼロになった。あわせて「finallyのみのtryは保護に数えない」「except/finally節の中身は保護・未保護のどちらにも数えない（外側にexcept付きtryがある場合のみ保護を維持）」という3状態の伝播を実装している。詳細は `src/Rules/RuleStyle002.pas` 冒頭コメント参照。
- P9で保留した検知範囲（今後の拡張候補）: `TFileStream.Create` のような修飾付き（`exprDot`）のリソース確保、`SysUtils.StrToInt(..)` のようなユニット修飾された呼び出し、`FileOpen`/`FileClose` 等のハンドルベースAPI（エラーコードを返すため try-except の有無が一貫性の指標になりにくい）はいずれも対象外。対象API名リスト（`CSystemFileApis` / `CSysUtilsApis`）が唯一のチューニングつまみであり、広げると誤検知、狭めると検知漏れになる。
- P4実装時の設計判断: `RuleRegistry`に登録されるルールインスタンスは`initialization`で一度だけ生成され、`RunLint`が複数ファイルを処理する間ずっと使い回される。RAWPACO-DEPR-001は「ファイル内でdeprecated宣言を集めてから使用箇所を照合する」という2パス処理(ファイル単位の一時的な状態)が必要だが、インスタンスフィールドに状態を持たせるとファイルをまたいで漏れる。これを避けるため`InterestedNodeTypes`を最上位の`root`ノードのみとし、1ファイルにつき1回のCheck呼び出しの中でローカル変数を使って自己完結した探索を行う設計とした(ASTWalker等の共通インフラは無改修)。複数ファイルを1回の実行で渡し、片方だけにdeprecated宣言がある状態で状態漏れがないことを実装時に確認済み。
- P8実装時に確認: `begin...end`は`block`ノード、try/repeat等の本体は`statements`ノードという**別のノード種別**になるが、いずれもフィールド名を持たず`assignment`/`if`/`ifElse`/`statement`等が直接並ぶ点は同じ。「隣接する2文」を見るルールは両方を`InterestedNodeTypes`に含める必要がある(`statements`だけだと`begin...end`直下では一度もCheckが呼ばれず静かに無効化される。実装時に一度これで全サンプル非検知になり気づいた)。また`Obj := TFoo.Create;`(括弧なし)は`assignment`のrhsが`exprDot`に、`Obj := TFoo.Create();`(括弧あり)は`exprCall`(entity=`exprDot`)になる違いも要考慮。詳細は`src/Rules/RuleDefense002.pas`冒頭コメント参照。

## FPC RTL/FCL シンボル一覧 (`data/fpc-rtl-symbols.txt`) について

- 生成コマンド: `bash tools/gen_fpc_symbols.sh`（Linux専用。`fpc-source` と `ppudump` が必要）。
- 生成時の環境: FPC 3.2.2（Ubuntu 24.04 の apt 版 `fpc-3.2.2 3.2.2+dfsg-32`）、ターゲット `x86_64-linux`。
- 方式の決定（静的コミット vs 動的生成）: **静的コミット**を採用。理由は (1) Windows CI の choco 版 freepascal に `fpc-source` が同梱されている保証がなく、これまでも標準ライブラリの検索パスで繰り返し問題が起きている、(2) `.ppu` の内容はターゲット OS/CPU ごとに変わるため、Linux CI と Windows CI でそれぞれ生成すると同じソースへの lint 結果が環境で変わってしまい再現性がない、(3) 生成物をリポジトリに置けば tree-sitter-pascal のピン留め（CLAUDE.mdルール2）と同じレベルの再現性が得られる。
- 抽出元は Pascal ソースではなく `.ppu`（`ppudump -VSD`）。RTL のソースは `{$i}` と `{$ifdef}` が深く、正しく展開するには実質 FPC のプリプロセッサ相当が必要になるため。`.ppu` は FPC 自身のコンパイル結果であり公開シンボルと deprecated ヒントの権威ある一覧そのもの。
- **プラットフォーム差の扱い**: `.ppu` は Linux 版なので、`SysUtils.Win32MajorVersion` のような Windows 専用シンボルが欠ける。これを補うため、`fpc-source` 側の各プラットフォーム版ソースの interface 部から識別子を総なめして「既知の名前(M行)」に足し込んでいる（`tools/source_idents.awk`）。M行は警告を抑制する方向にしか効かないので、多めに拾っても誤検知は増えない。
- ファイル形式は独自のタブ区切りテキスト。JSON にすると fcl-json 依存が増え、Windows CI のユニット検索パス問題を再燃させるリスクがあるため採用しなかった（`SysUtils` だけで読める形式にした）。
- ランタイムでのデータファイル探索順（`src/FPCSymbols.pas`）: 環境変数 `RAWPACO_DATA_DIR` → `<exeのディレクトリ>/data/` → `<exeのディレクトリ>/../data/`（開発時の `src/rawpaco` に対するリポジトリ直下 `data/`）→ `./data/`。見つからない場合、依存ルールは黙って何も報告しない（CLAUDE.mdルール5）。
- FPC のバージョンを上げる際は、このファイルを再生成し、deprecated 一覧の差分を確認すること。

## 自己lint到達状況

- 本ツール自身のソースへの自己適用: `./src/rawpaco src/*.pas src/Rules/*.pas src/rawpaco.lpr` をローカルで実行し、誤検知・真陽性ともにゼロを確認済み（2026-08-04時点、実装済み9ルール全部）。
- CIへの自己lintステップ追加: **実施済み**（CLAUDE.mdルール4）。`Makefile`に`selflint`ターゲットを新設し、Linux/Windows両ジョブの最後に追加した。7ルール全部を通した状態で既に警告ゼロを繰り返し確認済みだったため(各ルール実装時に自己lintで都度確認)、`--only`/`--exclude`によるルール個別スコープの段階導入は経ずに一括でCI組み込みを行った。今後新しいルールが自己ソースに誤検知/真陽性を出す場合は、その時点で`--only`/`--exclude`の実装を検討する。

## tree-sitter本体・tree-sitter-pascalのvendoring方針（確定）

- 方式: OS提供の共有ライブラリ（apt/choco等）には依存せず、ソースをリポジトリにvendoringしCコンパイラで静的リンクする。CLAUDE.mdルール2（バージョン固定）にも合致。
- `vendor/tree-sitter/`: tree-sitter本体ランタイムを `v0.24.7` で固定。`lib/src/lib.c`（単一ファイル版アマルガメーション）と `lib/include/tree_sitter/api.h` を取り込み済み。ABIバージョンは14（`TREE_SITTER_LANGUAGE_VERSION`）。
- `vendor/tree-sitter-pascal/`: `v0.10.2` で固定。生成済み `src/parser.c` を取り込み済み（外部スキャナ(scanner.c)なし）。生成時ABIも14で一致（`LANGUAGE_VERSION 14`）。tree-sitter本体はABI13〜14を互換サポートしており組み合わせ上の問題なし。
- ビルド: リポジトリルートの `Makefile` が `vendor/*/src/*.c` を `gcc` でコンパイルし `build/*.o` を生成、`src/TSBindings.pas` の `{$L ../build/tree-sitter.o}` 等で静的リンクする。`make` 一発で `src/rawpaco` まで生成される。
- 既知の落とし穴: `-k` 経由で手動に `-lc` を渡すとFPCがダイナミックリンカのパスを誤検出し（このUbuntu環境では存在しない `/lib/ld64.so.1` になる）実行不能バイナリが生成される。`{$linklib c}` ディレクティブでFPC自身にlibcリンクを解決させることで回避（`TSBindings.pas` にコメントあり）。
- Windows CI初回実行（2026-08-02, run 30759838476）: `build-linux` は成功。`build-windows` は `fpc: command not found` で失敗。原因はchocoインストールによるマシンPATH（レジストリ）更新が、GitHub Actionsの同一ジョブ内後続ステップ（別プロセスとして起動）に反映されないため。gccが動いていたのは、mingwインストールが効いたのではなく、Windowsランナーに元々含まれる別経路のgcc（Strawberry Perl等）がPATHにあったためと推測。対策として、chocoインストール直後に `fpc.exe` / `gcc.exe` の実際の設置場所を検索し `$GITHUB_PATH` に明示追記した。
- Windows CI 2回目実行（run 30760907748）: `fpc` は見つかるようになったが今度は `Illegal COFF Magic`（32bit/64bitのオブジェクト形式不一致）と `Import library not found for c` で失敗。`{$linklib c}` はLinux固有の対処（ld64.so.1問題の回避）であり、Windowsには対応する`c`という名のインポートライブラリが存在せずエラーになるため `{$IFDEF LINUX}` で囲みLinux限定にした（`TSBindings.pas`。これは3回目実行でも解消を確認）。
- Windows CI 3回目実行（run 30761222949）: `Illegal COFF Magic` 対策として `-Px86_64 -Twin64` を試したが `ppcx64.exe can't be executed`（error code 2 = ファイルが存在しない）で失敗。chocoの `freepascal` パッケージのインストールスクリプト(`ChocolateyInstall.ps1`)を直接取得して確認したところ、64bit OS向けに `fpc-3.2.2.win32.and.win64.exe`（win64コンポーネント追加インストーラ）を実行してはいるが、共有の `setup.inf`（`Components=base,binutils,docs,ide,utils,make,demo,gdb,units,examples`）はこのインストーラのコンポーネントID体系と一致しておらず、実際には `ppcx64.exe` が配置されないと判明。
- 対策1（64bit側を諦め32bitに統一する方針）: `ppc386.exe`にgcc側を合わせる。`choco install` 前に `$env:ChocolateyForceX86 = 'true'` を設定して試みたが、Windows CI 4回目実行（run 30761437586）で確認したところ効果がなく、mingwパッケージは相変わらずx86_64ビルドをダウンロードしていた（ログで確認）ため、依然`Illegal COFF Magic`で失敗。
- 対策2: Chocolatey公式ドキュメントを確認したところ、32bit強制の正しい方法は環境変数ではなく `choco install ... --x86` というコマンドラインオプションだった。`--x86`に切り替えたところ、Windows CI 5回目実行（run 30761651380）で `Illegal COFF Magic` は解消し32bit同士でリンクできるようになった。
- Windows CI 5回目実行の残課題: 今度は `malloc`/`memcpy`/`QueryPerformanceCounter`/`___mingw_vsnprintf`/`___udivdi3` 等28個の `Undefined symbol` でリンク失敗。原因はFPC自身のリンカ(ld.exe)がgccと違いlibgcc/libmingwex/libmingw32/CRT(ucrt)/kernel32を暗黙にリンクしないため。対策として、CI側でchocoのmingwインストール先から該当する`.a`ファイル(libmingwex.a, libmingw32.a, libgcc.a, libkernel32.a, libucrt.a等)の実際の設置ディレクトリを動的検索し`-Fl`でFPCに渡すようにし、`TSBindings.pas`側に`{$IFDEF MSWINDOWS}`で`{$linklib mingwex/mingw32/gcc/ucrt/kernel32}`を追加した。pinしているmingw(niXman mingw-builds 16.1.0)がucrtランタイムなので`ucrt`を指定（`msvcrt`ではない）。
- 32bit方針の再検討: 「32bit強制がChocolatey環境変数ではなくCLIオプションだった」という経緯を踏まえ、64bit側で同様の見落としがないか再確認した（ユーザー指摘）。SourceForgeの配布物一覧を調べたところ、chocoが使う共有setup.infに依存しない単機能のwin64クロスコンパイラ追加インストーラ `fpc-3.2.2.i386-win32.cross.x86_64-win64.exe` が別途配布されていると判明。これを直接ダウンロードし`/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /DIR=C:\tools\freepascal`でサイレントインストールする方式に変更し、mingw側も32bit強制(`--x86`)をやめてネイティブのx86_64ビルドに戻した。fpc呼び出しは`-Px86_64 -Twin64`。
- Windows CI 6回目実行（run 30761956791）: `Invoke-WebRequest` でのダウンロードが実行可能ファイルとして壊れており（SourceForgeのミラー選択リダイレクトを正しく辿れなかったと推測）、`Start-Process`が「corrupted and unreadable」で失敗。ダウンロード手段を`curl.exe`（Windowsランナー標準搭載）に切替え。
- Windows CI 7回目実行（run 30762105705）: `curl.exe`でのダウンロード自体は成功したが、サイレントインストール後も`ppcx64.exe`が見つからず失敗。Windows実機がなくInno Setupのサイレントインストール引数（`/DIR=`の形式や必要な`/COMPONENTS=`指定など）を検証できず、これ以上64bit側を追うのはCI往復での試行錯誤になり非効率と判断。ユーザーと相談の上、64bit方針は断念し32bitに戻すことで合意（`choco install -y freepascal mingw --x86`、fpc呼び出しはプレーンな`fpc src/rawpaco.lpr`に戻す）。5回目実行で32bit同士のアーキテクチャ一致は既に確認済みなので、残るは5回目で判明したUndefined symbol対策（mingwランタイムライブラリの動的検索+linklib、既に実装済み・bitness非依存）のみのはず。
- Windows CI 8回目実行（run 30762263102）: mingwランタイムライブラリの動的検索+linklib対策により28個あったUndefined symbolはほぼ解消したが、`atexit`だけが未解決で残った。原因はlibmingw32/libmingwex/libgccが互いに依存し合う循環参照（mingw-w64で既知の構造）で、`{$linklib}`を並べる素朴な方式ではGNU ldが1回の左→右走査で解決しきれないため。
- Windows CI 9回目実行（run 30762403167）: 対策として`{$linklib}`ディレクティブをやめ、CI側のfpc呼び出しで`-k"--start-group" -lmingwex -lmingw32 -lgcc -lucrt -lkernel32 -k"--end-group"`という生ld引数として渡す方式を試したが、28個のUndefined symbolが全て復活（8回目より悪化）。`-k`経由での`--start-group`/`--end-group`受け渡しが機能していないと判明（fpcの`-k`オプションでの二重ダッシュ引数の扱いに問題がある可能性。原因未特定）。対策として`-k`方式は撤回し、8回目で27/28まで解決していた`{$linklib}`方式に戻した上で、循環依存のあるmingwex/mingw32/gccをucrt/kernel32の後にもう一度並べる（`--start-group`が登場する以前からの古典的な2周回避策）よう変更。
- Windows CI 10回目実行（run 30763225203）: 2周回避策でも`atexit`だけは変化なく未解決のまま。つまりmingwex/mingw32/gcc/ucrt/kernel32のいずれにもatexitは存在しないと判明。pinしているmingw(niXman mingw-builds 16.1.0)は"posix"スレッディングモデルのビルド（ダウンロードURLに`-posix-`と明記）であり、posixスレッディング版mingw-w64はatexitのスレッドセーフな登録処理をlibwinpthreadに依存することが多いという仮説のもと、`libwinpthread.a`を検索対象に追加し`{$linklib winpthread}`を足した。
- Windows CI 11回目実行（run 30763379093）: `libwinpthread`追加でも`atexit`は変化なし。推測での対処が限界に達したため、CI上に一時的な診断ステップ（`nm`で全`.a`ファイルを直接調べる）を追加して実機で確認する方針に切替え。
- 診断結果（run 30763650485、詳細ログは会話内に記録）: pinしているmingw-w64全体（mingwex/mingw32/gcc/ucrt/kernel32/winpthread/msvcrt系/crtdll等、opt配下含め探索した全`.a`）を`nm`で走査したが、プレーンな`atexit`という名の定義済みシンボルはどこにも存在しなかった。関連シンボルとして`__crt_atexit`（`libmsvcrt.a`等に`T`=定義済みで実在）、`___cxa_atexit`、`__register_thread_local_exe_atexit_callback`は見つかった。これはUCRT環境の既知の仕様で、`atexit()`は`<stdlib.h>`のインライン展開でのみ提供され実体は`_crt_atexit`であり、ヘッダ経由を通らない形でコンパイルされたコード（vendorのCソースをgcc -cで直接コンパイルしている今回のケース）ではプレーンな`atexit`シンボル自体がどのライブラリにも存在しないため原理的に解決不可能と判明。
- 対策（第1版）: `src/win32_atexit_shim.c`を新設し、`atexit`から`_crt_atexit`へ転送する薄いラッパーを自前で提供する（`extern int _crt_atexit(void (*)(void));`を呼ぶだけ）。CI側で`gcc -c src/win32_atexit_shim.c -o build/win32_atexit_shim.o`としてコンパイルし、`TSBindings.pas`の`{$IFDEF MSWINDOWS}`ブロックに`{$L ../build/win32_atexit_shim.o}`を追加してリンクする。診断用の一時ステップ（`Diagnose atexit symbol location`）は原因判明のため削除済み。
- Windows CI 12回目実行（run 30764064796）: 上記のCシム自体はコンパイル成功したが、`{$L}`で埋め込んだ途端に`ppc386.exe`自体が`Compilation raised exception internally / EAccessViolation`でクラッシュした。原因はおそらく極小オブジェクトファイル（1関数のみ）に対するFPC側のCOFFリーダーのエッジケースバグ（{$L}はFPC自身がオブジェクトを事前解析するため）。ユーザー提案で「ローカルクロスコンパイルした成果物をコミット」も検討したが、ビルド成果物を非gitignore対象にする案はCLAUDE.mdのバージョン固定・再現可能ビルド方針（ソースから再現できることが前提）に反するため不採用。
- 対策（第2版）: C側の実装と`{$L}`埋め込みを完全にやめ、`src/win32_atexit_shim.c`は削除。代わりに`TSBindings.pas`のimplementation部で、Pascal側から`_crt_atexit`へ転送する関数を書き`cdecl; public name 'atexit';`でエクスポートする方式に変更（`WindowsAtExitShim`関数）。FPC自身のCOFFリーダーを経由する外部オブジェクトファイルが一切不要になり、クラッシュ要因は解消。
- Windows CI 13回目実行（run 30764301814）: クラッシュは解消したが、まだ`Undefined symbol: _atexit`が残った（1個のみ、クラッシュなし）。原因は`public name`が明示的な名前をそのまま使うため、win32ターゲットでcdecl関数の名前省略時のみ自動付与される先頭アンダースコアの恩恵を受けなかったこと。エクスポート名を`public name 'atexit'`から`public name '_atexit'`へ変更（アンダースコアを明示）して解決を試みた。
- Windows CI 14回目実行（run 30764487825）: `public name '_atexit'`にした途端、run 12（Cシムを`{$L}`で埋め込んだ時）と全く同じクラッシュアドレス（$005BBF37等）でEAccessViolationが再発。{$L}によるオブジェクト読み込みとpublic nameによるシンボル書き出しという別々の操作が同一のクラッシュ箇所に落ちることから、FPC(ppc386.exe 3.2.2)が先頭アンダースコア始まりのシンボル名（`_atexit`）を内部処理する経路に何らかのバグ（もしくは予約語的な特別扱いとの衝突）がある可能性が高いと推測。
- **真因の特定（15〜18回目実行、ブランチ`windows-ci-linker`）**: 「ppc386.exeのEAccessViolation」も「`-k`が効かない」も、**FPC 3.2.2のwin32ターゲットが既定で内部リンカ(`ld_int_windows`)を使う**ことが共通の原因だった。`compiler/systems/i_win.pas`の`system_i386_win32_info`は`link : ld_int_windows; linkextern : ld_windows;`となっており、`-Xe`を付けない限り外部の`ld.exe`は使われない。
  - `-k`が無効だった件（9回目実行の謎）: 内部リンカは`-k`で渡したオプションを一切見ないため。`-Xe`を付けると`-k`は期待どおりldに届く。
  - EAccessViolationの件: `{$L}`でのオブジェクト読み込みと`public name '_atexit'`でのシンボル書き出しという別経路が同じアドレスでクラッシュしたのは、**どちらも「未定義シンボルが全て解決してリンクが最終段階まで進んだ」ケースだった**ため。先頭アンダースコアは無関係で、内部リンカがこのプロジェクトのイメージを書き出す段階でクラッシュしていた。`public name 'atexit'`（アンダースコアなし）でクラッシュしなかったのは、未定義シンボルで手前で停止していたから。`-Xe`で外部ldに切り替えるとクラッシュしない。
- 15回目実行（run 30771314121, 診断マトリクス）:
  - `nm -A --undefined-only`で判明: `atexit`を参照しているのは`libmingwex.a(misc.o)`と`libmingw32.a(gccmain.o)`。**vendorのCソース自身はatexitを一切使っていない**（`grep`でも確認）。
  - 内部リンカ（従来どおり）: `Undefined symbol: _atexit`のまま。`-Xi -kシム.o`でも同じ（＝内部リンカは`-k`を無視）。
  - `-Xe`（外部ld）: クラッシュせず、ldからの通常のエラーになった。残ったのは2件 — `undefined reference to 'atexit'` と `multiple definition of '_tls_used'`。
  - `-Xe -kbuild/win32_atexit_shim.o`: atexitは解決。`_tls_used`のみ残る。
- 16回目実行（run 30805120637）:
  - `-k--allow-multiple-definition`を追加 → **リンク成功、exeが生成された**。ただし実行すると`Exec format error`(ENOEXEC, exit 126)。
  - `libmingw32.a`から`tlssup.o`を`ar d`で除去する案は失敗。FPCの`sysinitpas.o`が`___tls_start__`/`___tls_end__`を参照しており、`.tls`セクションの供給源としてtlssup.oが必要（「defined in discarded section `.tls'」）。よって`--allow-multiple-definition`で先勝ち（FPC側の定義が採用される）にするのが正解。
  - `-k-lmingwex`のような`-l`を`-k`で渡す方式は使えないと判明（`cannot find -lmingwex`）。FPCは`-Fl`で与えた検索パスをldのコマンドラインではなくリンカスクリプトの`SEARCH_DIR`として渡すため、コマンドライン側の`-l`からは見えない。したがって`--start-group`/`--end-group`は事実上使えず、`{$linklib}`を2周並べる回避策を維持する。
- 17〜18回目実行（run 30806453652 / 30806733089）: `Exec format error`の原因はPEの構造。`objdump -h`で見ると、mingwのランタイムオブジェクトが持ち込んだDWARF5のデバッグ情報が`.debug_loclists`/`.debug_line_str`/`.debug_rnglists`として**VMA 0のまま`.text`より前のセクションとしてPEセクションテーブルに残っており**、Windowsローダがイメージを拒否していた。`-Xs`（FPCのstrip）でも`-k--strip-debug`（ld側）でも解消し、いずれも生成されたexeが正常に起動して自己チェック出力を出すことを確認した。より限定的な`-k--strip-debug`（シンボルテーブルは残す）を採用。
- **確定した Windows CI のビルドコマンド**:
  ```
  fpc -Xe -kbuild/win32_atexit_shim.o -k--allow-multiple-definition -k--strip-debug <-Fl...> src/rawpaco.lpr
  ```
  `src/win32_atexit_shim.c`（`atexit` → `_crt_atexit` への転送、Windows専用）はCI側で`gcc -c`し、`{$L}`ではなく`-k`でldに直接渡す。`{$L}`はFPC自身がCOFFを解析する経路に入るため使わない。
- RAWPACO-DEFENSE-001実装時のWindows CI失敗（run 30815112925）: `src/Diagnostics.pas`が`uses Generics.Collections`した途端、`Fatal: Can't find unit Generics.Collections`。Linux(apt版)の`/etc/fpc.cfg`は`-Fu.../units/$fpctarget/*`というワイルドカードでrtl-genericsパッケージ配下も自動的に検索パスへ含めているが、choco版freepascalのfpc.cfgは同様になっていないと推測される。
- 2回目の失敗（run 30815734423）: `rtl-generics`ディレクトリだけを個別に`-Fu`で足したところ、今度は依存先の`Fatal: Can't find unit Variants used by Generics.Defaults`が発覚。パッケージ単位で1つずつ`-Fu`を足す芋づる式のホワックアモグラは非効率と判断し、Linuxのfpc.cfgと同じ`-Fu<dir>/*`ワイルドカード方式に切り替えた。`rtl-generics`ディレクトリの親(`units\i386-win32`、fpctarget相当)を検出し、`-Fu$FPC_UNITS_ROOT/*`として全パッケージサブディレクトリを一括で検索パスに含めるようにした（`.github/workflows/ci.yml`）。未検証・要フォローアップ。
- 64bit（`ppcx64.exe`）経路について: 追わない方針で決着。理由は(1)32bitのままで全ての問題が解決したこと、(2)`i_win.pas`の`system_x86_64_win64_info`も`link : ld_int_windows`であり、win64でも既定は同じ内部リンカなので`-Xe`等の同じ対処が結局必要になること、(3)chocoの`freepascal`パッケージでは`ppcx64.exe`が配置されない制約（7回目実行までで確認済み）が残ること。将来どうしても64bitが必要になった場合の候補としては、`choco install lazarus`（win64版Lazarusインストーラはネイティブのwin64 FPC = `ppcx64.exe`を同梱する）や`fpcupdeluxe`/`ollydev/setup-lazarus`系のGitHub Actionがあるが、いずれも未検証。

## 設定ファイル (`rawpaco.json`) について

- スキーマ・探索順・既定値の根拠は `docs/CONFIG.md` を参照。実装は `src/RawpacoConfig.pas`。
- 形式は **JSON（fcl-json: `fpjson` + `jsonparser`）**。`fcl-json` が Windows CI のユニット検索パスで解決できるかを、ルール本体を作り込む前にコミット `e53201e` の1回で実機確認した（CI run 30859609754、**CI設定の変更なしで Linux/Windows とも成功**）。現行 CI の `-Fu<unitsroot>/*` ワイルドカード方式が効いている。今後 fcl-* の他パッケージを使う場合も同様に通る見込み。
- CI（Windows）で `choco install freepascal` が SourceForge の 404 で失敗することがある（2026-08-04 に1回発生、再実行で成功）。CI設定の問題ではなく上流の一時的障害なので、失敗時はまず `gh run rerun <id> --failed` を試すこと。

## `--only` / `--exclude` オプションについて

- 設計書5節・8節（担当Sonnet5）。実装は `src/RuleRegistry.pas`（`AllRuleIds`/`SetRuleFilter`、ディスパッチ側の`RuleIsEnabled`によるフィルタ）と `src/rawpaco.lpr`（CLI引数のパース）。
- `--only=ID[,ID...]` は列挙したルールIDだけを有効化、`--exclude=ID[,ID...]` は列挙したIDだけを無効化する。両方同時指定はどう組み合わせるかが自明でないため明示的にエラー（rc=2）。未知のルールID、値が空（`--only=`単体）もエラーにする（`rawpaco.json`の未知キーと同じく黙って無視しない方針、CLAUDE.mdルール5）。
- `rawpaco.json` 側にはルール単位の有効・無効を書くキーを**意図的に設けていない**。ルールのオンオフはCLIフラグ(実行のたびに変えるもの)、命名規則の接頭辞等は設定ファイル(プロジェクトに固定するもの)、と層を分けている。将来的にプロジェクト単位で特定ルールを恒久的に無効化したいという要求が出た場合は、そのとき改めて設定ファイル側のキーを検討する。
- `tests/run_tests.sh` の `flag_case`/`flag_error_case` で配線を確認（DEFENSE-001/SEC-001の2ファイルを同時に渡し、フィルタで片方だけが黙ることを見る）。
- **バグ修正済み（2026-08-04、Fable5のレビューで発見）**: 空値チェックが元々「`--only`/`--exclude`両方とも空か」をループ完了後にまとめて見ていたため、`--only= --exclude=RAWPACO-X`のように片方だけが空でもう片方に値がある場合、空の方が「フラグ自体が現れていない」扱いになりすり抜けていた。各フラグの値を読んだその場（パースループ内）で個別にチェックするよう修正し、`tests/run_tests.sh`に回帰テスト（`empty --only value with non-empty --exclude`等）を追加した。

## 未着手・保留中

- 設計書 P1〜P9・`--only`/`--exclude` は全て実装済み（各ルールで見送った拡張候補は「tree-sitter-pascal 文法カバレッジの既知の穴」セクション内に個別記載）。
- **設計書4節（診断結果の出力形式）は未実装のまま残っている**（レビューで判明、2026-08-04）。具体的には次の3つ:
  1. `--format` オプション自体が存在しない。
  2. `github`（GitHub Actions ワークフローコマンド形式）・`json` 出力が無く、`text` 形式（`src/Diagnostics.pas` の `FormatDiagnosticText`）しか出せない。
  3. `// rawpaco:ignore <RuleId>` によるインライン抑制コメント機構が無い。
  `docs/SYSTEM_FLOW.md`・`docs/RULE_ENGINE_DESIGN.md` はこれらが実装済みであるかのような記述になっていたため、今回のレビューで実装状況の注記を追加した。着手する場合は改めて優先度を検討すること（自己lint運用上は `text` 形式のみで足りているため、CI上の実害は今のところ無い）。

## 直近セッションのメモ

- FPC開発環境をローカルに導入済み（Ubuntu 24.04、apt経由: fpc 3.2.2+dfsg-32, fpc-source, lazarus 3.0）。
- tree-sitter本体・tree-sitter-pascalのvendoring、Makefileによるビルド、`src/rawpaco.lpr` からのtree-sitter-pascal経由パース（自己チェック用の最小プログラム）まで動作確認済み（Linux）。詳細は上記セクション参照。
- `.github/workflows/ci.yml` を追加（Linux/Windowsの2ジョブ）。LinuxはCI相当のローカル手順（apt install fpc → make → 実行）を確認済み。Windows側も実機CIでビルド＋自己チェック実行まで成功を確認済み（上記参照）。
- ルールエンジン全体の設計を `docs/RULE_ENGINE_DESIGN.md` にまとめた（API設計、AI生成コード特有の5問題点ごとの検知可否、サンプル配置、出力形式、自己lintへの道筋、実装優先順位付き第1弾ルール案、実装担当（Sonnet5/Opus5）の振り分けを含む）。
- 次のステップ: Windows CIジョブの実機検証、上記設計書の優先順位に従った実際のlintルール第1号の実装（positive/negativeサンプル込み、CLAUDE.mdルール3）、ルール実装後に自己lintのCI組み込み（ルール4）。

## 関連プロジェクト（参考・棚卸し対象外）

- CodeTools方式によるFPC/Lazarus向け静的解析ツールは別リポジトリで構想のみ管理（GPL-3.0-or-later予定、実装未着手）。詳細は当該リポジトリのREADME参照。本HANDOFF.mdでは追跡しない。
