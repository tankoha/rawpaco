# ルールエンジン設計書

*This document is a Japanese translation kept for reference. The canonical, up-to-date version is [docs/RULE_ENGINE_DESIGN.md](RULE_ENGINE_DESIGN.md) (English).*

このドキュメントは rawpaco の lint ルールエンジン全体の設計をまとめたものです。CLAUDE.md の開発ルール、README.md の目的・実装方針を前提とし、これらと矛盾しないように設計しています。決着していない大きな方針転換候補は「8. 未決事項・提案」に切り出し、断定を避けています。全体のシステムフローをMermaid図で俯瞰したい場合は [docs/SYSTEM_FLOW_jp.md](SYSTEM_FLOW_jp.md) を参照してください。

実装は Sonnet5 が担当する前提で書いています。各項目の末尾に担当を明記しており、省略時は Sonnet5 とみなします（依頼内容の指示に準拠）。複雑なアルゴリズム設計・曖昧な仕様判断・大きなアーキテクチャ決定を要する項目には「担当: Opus5」を明記しています。

## 0. 前提・制約

rawpaco は tree-sitter-pascal による**構文解析のみ**を行うツールであり、以下ができません。

- 型解決（変数・式の型を確定できない。`identifier` が何を指すかは構文的な位置関係からしか推測できない）
- スコープ解決（宣言と使用箇所を跨いだ名前解決。同名の識別子が別スコープに複数あっても区別できない）
- 外部レジストリ・パッケージマネージャへの照会（あるユニット・パッケージが実在するか、正しいバージョンかをネットワーク越しに確認する手段がない）
- 実行時情報（値の実際の内容、null 安全性の証明など）

このため、以下の設計全体を通じて「構文パターンとして安全に検知できるもの」と「意味・型情報がないと原理的に検知できないもの」を区別し、後者については代替案（バンドルする静的データ、compiler自体をオラクルとして使う、等）を明記します。CLAUDE.md ルール5（false positive 回避優先、疑わしきは見逃す）がある以上、「検知できそうだが確信が持てない」ものは意図的にスコープから外しています。

## 1. ルールエンジンAPI設計

### 1.1 全体アーキテクチャ

```
rawpaco.lpr (CLIエントリポイント)
  └─ LintDriver.pas   … 対象ファイル列挙、パース、走査、診断集約、出力、終了コード決定
       ├─ ASTWalker.pas   … TSNodeツリーを tree-sitter cursor APIで走査する汎用ドライバ
       ├─ RuleRegistry.pas … ルールの登録・ノード種別ごとのディスパッチテーブル
       ├─ Diagnostics.pas  … TDiagnostic レコード、出力フォーマッタ
       └─ Rules/*.pas      … ルール本体（1ルール1ユニット）
```

現状の `src/rawpaco.lpr` は tree-sitter-pascal が動くことを確認するだけの自己チェックプログラムであり、上記の構造はまだ存在しません。ルール第1号の実装時にあわせて `LintDriver`/`ASTWalker`/`RuleRegistry`/`Diagnostics` を切り出すことを想定しています。（担当: Sonnet5）

### 1.2 TSBindings.pas の拡張が必要

現状の `src/TSBindings.pas` は自己チェック用の最小限の関数（`ts_parser_new`, `ts_parser_set_language`, `ts_parser_parse_string`, `ts_tree_root_node`, `ts_tree_delete`, `ts_node_string`, `ts_parser_delete`）しか宣言しておらず、AST を走査するための関数が不足しています。ルールエンジンの実装に先立って、少なくとも以下を追加する必要があります（関数名・シグネチャは `vendor/tree-sitter/include/tree_sitter/api.h` で確認済み。CLAUDE.mdルール1に従い、この節で使う関数はすべて同ヘッダに実在する名前のみを挙げています）。

- `ts_node_type(TSNode): PAnsiChar` — ノード種別名（`node-types.json` の `type` と対応）
- `ts_node_is_null(TSNode): Boolean`
- `ts_node_child_count(TSNode): LongWord` / `ts_node_named_child_count(TSNode): LongWord`
- `ts_node_child(TSNode; index: LongWord): TSNode` / `ts_node_named_child(TSNode; index: LongWord): TSNode`
- `ts_node_field_name_for_child(TSNode; index: LongWord): PAnsiChar` — フィールド名（`node-types.json` の `fields` のキー、例: `exprBinary` の `lhs`/`operator`/`rhs`）付きの子を扱うために必要
- `ts_node_start_point(TSNode): TSPoint` / `ts_node_end_point(TSNode): TSPoint` — 診断の行・列番号に使用（`TSPoint = record row, column: LongWord end;` を `api.h` の定義通りに追加）
- カーソルAPI（子ノードが多い場合に `ts_node_child` の毎回の再計算を避けるための効率化。将来大きなファイルを扱う際に有効）: `ts_tree_cursor_new`, `ts_tree_cursor_delete`, `ts_tree_cursor_current_node`, `ts_tree_cursor_current_field_name`, `ts_tree_cursor_goto_first_child`, `ts_tree_cursor_goto_next_sibling`, `ts_tree_cursor_goto_parent`

ブートストラップ段階では `ts_node_child`/`ts_node_child_count` による素朴な再帰下降で十分であり、カーソルAPIへの切り替えは最適化が必要になった時点で構わないと考えます。（担当: Sonnet5。ただし関数追加のたびに CLAUDE.md ルール1の照合先が `vendor/tree-sitter/include/tree_sitter/api.h` であることを踏まえ、都度シグネチャを確認しコメントに出典を残すこと。）

### 1.3 走査ドライバ (ASTWalker.pas)

ノード種別文字列をキーにしたディスパッチテーブルを持つ、単純な深さ優先走査を提案します。

```pascal
type
  TNodeVisitProc = procedure(const Node: TSNode; Ctx: TLintContext) of object;

// ノード種別名 -> そのノードに関心を持つルールのVisitProcリスト
// (RuleRegistryが「自分はexprBinaryとassignmentだけ見る」のように
//  関心のあるノード種別を宣言し、走査側は全ルールを毎ノードで
//  呼び出すのではなく該当するものだけを呼ぶ。ノード種別は271種と
//  少なくないため、全ルール全ノード総当たりを避ける設計判断。)
procedure WalkTree(const Root: TSNode; Ctx: TLintContext);
```

走査自体はルールのロジックを一切知らず、`RuleRegistry` が管理するディスパッチテーブルを引くだけにします。ルールを追加してもこのファイルは変更不要にするのが狙いです。（担当: Sonnet5）

### 1.4 ルールの実装単位とインターフェース

1ルール = 1ユニット（`src/Rules/RuleXxx.pas`）を基本単位とします。ルールは以下のインターフェースを実装します。

```pascal
type
  TSeverity = (svWarning); // 将来 svError 等を追加する余地は残すが、
                           // 現時点では全ルールを svWarning 統一とする
                           // (CLAUDE.mdルール5: 誤検知回避優先の方針上、
                           //  「これはエラーで問答無用でCIを落とす」と
                           //  断定できるルールはまだ無いと判断したため)

  IRawpacoRule = interface
    function RuleId: string;         // 例: 'RAWPACO-SEC-001'
    function Description: string;    // 1行説明（診断メッセージの土台）
    function InterestedNodeTypes: TStringArray; // ['exprBinary', 'assignment'] 等
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;
```

- `RuleId` は `RAWPACO-<カテゴリ>-<連番>` 形式に統一します（カテゴリ例: `SEC`=セキュリティ, `STYLE`=一貫性・命名, `DEPR`=非推奨API, `DEFENSE`=過剰防御, `HALLUC`=hallucination）。カテゴリは「5つの問題点」との対応を追跡しやすくするためのものです。
- `InterestedNodeTypes` を宣言させることで、`RuleRegistry` がディスパッチテーブルを構築できます。
- `Check` 内で問題を見つけたら `Ctx.Report(RuleId, Message, Node)` を呼びます。`Ctx` が `ts_node_start_point` からファイル名・行・列を引いて `TDiagnostic` を組み立てます。

**登録方法について（FPCの制約）**: FPC には実行時のアセンブリスキャンやアノテーション自動収集の仕組みがありません。そのため「ユニットを置くだけで自動的に有効になる」プラグイン方式は実現できず、各ルールユニットは
1. `initialization` セクションで `RuleRegistry.Register(TRuleXxx.Create)` を呼ぶ
2. かつ、そのユニット自体を `Rules/AllRules.pas` の `uses` 節に列挙する（`initialization` はユニットが実際に `uses` されて初めて実行されるため）

の両方が必要です。新しいルールを追加した際に `AllRules.pas` への追記を忘れると静かに無効なままになる、という失敗しやすいポイントなので、`AllRules.pas` の冒頭コメントに「なぜ」（CLAUDE.mdルール8）としてこの制約を明記しておくこと。（担当: Sonnet5）

### 1.5 診断とコンテキスト

```pascal
type
  TDiagnostic = record
    RuleId: string;
    Message: string;
    FileName: string;
    Line, Column: LongWord;   // 1-origin（人間向け表示に合わせる。
                               // ts_node_start_pointは0-originなので+1する）
    Severity: TSeverity;
  end;

  TLintContext = class
  private
    FDiagnostics: specialize TList<TDiagnostic>; // Generics.Collections
    FFileName: string;
    FSource: PAnsiChar; // ソース全体。identifier等のバイト範囲からテキストを
                          // 切り出すために保持（ts_node_stringは括弧付きの
                          // S式表現しか返さないため、実際のトークン文字列が
                          // 必要な場合はソースバイト列から自前で切り出す）
  public
    procedure Report(const RuleId, Message: string; const Node: TSNode);
    property Diagnostics: specialize TList<TDiagnostic> read FDiagnostics;
  end;
```

`ts_node_string` はS式のデバッグ表現しか返さないため、識別子名や文字列リテラルの実際のテキストが必要なルール（命名規則チェック、シークレット文字列検知など）は `ts_node_start_byte`/`ts_node_end_byte`（`api.h` に実在、`TSBindings.pas` への追加が必要）でソースバイト列から部分文字列を切り出す方式にします。（担当: Sonnet5）

### 1.6 実行フロー（擬似コード）

```
for each 対象ファイル in CLIで指定されたパス:
  Source := ファイル読み込み
  Tree := ts_parser_parse_string(...)
  Root := ts_tree_root_node(Tree)
  Ctx := TLintContext.Create(ファイル名, Source)
  WalkTree(Root, Ctx)          // RuleRegistryのディスパッチテーブルを引いて各ルールのCheckを呼ぶ
  AllDiagnostics += Ctx.Diagnostics
  ts_tree_delete(Tree)

出力フォーマッタに AllDiagnostics を渡して出力（5節参照）
ExitCode := AllDiagnostics が空でなければ 1、空なら 0
```

（担当: Sonnet5）

## 2. 5つの問題点ごとの検知方針

### 2.1 一貫性のムラ（命名規則・エラーハンドリングの不統一）

- **検知できる部分**: 固定の命名規則（型名は `T` プレフィックス、フィールドは `F` プレフィックス等）は `declType`/`declField`/`declProc` 等のノードから識別子名を取り出し、正規表現的なパターンと突き合わせるだけで検知できます。ただし「何が正しい規則か」はプロジェクトごとに違うため、規則自体はハードコードせず設定ファイル（後述）で定義できるようにする必要があります。
- **検知が難しい部分**: 「セッションを跨ぐとエラーハンドリングの流儀がブレる」という本来の問題は、*同じ意味的な操作*を複数箇所で行った際に、ある箇所は `try-except` で保護し別の箇所は素通しにしている、という**ファイル横断・意味的な比較**です。tree-sitter は個々の構文木しか見せてくれず、「この2つの `exprCall` が意味的に同種の操作である」という判断はできません。妥協案として、同一ファイル内で「特定の呼び出しパターン（例: `Assign`/`Reset`/`Rewrite` などのファイルI/O系呼び出し）が `try` ブロックの中にあるか外にあるか」の構文的な有無だけを見て、同一ファイル内での混在を検知することは可能です（意味の同一性は判定せず、あくまで表面上のAPI呼び出し名の一致で近似する、緩い実装）。これはCLAUDE.mdルール8の「false positive回避のための緩め実装」に該当するため、実装時はその理由をコメントに残すこと。
- セッション（コミット）を跨いだ命名規則ドリフトの検出（例: 過去のコミットと比べて命名が変わった）は、単一ファイルの構文解析の範囲外（git blame等の履歴情報が必要）であり、本設計では扱いません。「8. 未決事項」に発展案として記載します。

### 2.2 過剰な防御的コーディング

- **検知できる部分（低リスク）**:
  - 空の `except` ハンドラ（例外を握りつぶして何もしない）: `exceptionHandler`/`exceptionElse` の `body`/`children` が実質空、または単なる `;` のみ。これは「防御的コーディングのやりすぎ」であると同時に「セキュリティ考慮漏れ」（エラーを握りつぶして異常を隠蔽する）の両方に該当する、汎用性の高いパターンです。
  - オブジェクト生成直後の無意味な nil チェック: `Obj := TFoo.Create(...)` の直後の文が `if Assigned(Obj) then` である場合。Pascal のコンストラクタは（例外を送出しない限り）nil を返さないため、この直後チェックは常に真になり無意味です。ただし「直後」の判定は同一 `statements` 内で隣接する文に限定し、間に他の処理が挟まる場合は対象外とする等、狭いスコープに留めて誤検知を避けます。
- **検知が困難な部分**: 「求められていないエッジケース処理を大量に追加している」かどうかは、そもそも何が「求められている」仕様かを rawpaco は知り得ません（要求仕様は自然言語のIssueやPRの説明に存在し、構文木には現れません）。これは意味論的な要否判断であり、構文解析だけでは原理的に検知不可能です。本設計では「意味に関わらず常に安全に指摘できる具体的パターン」（上記2つ）にスコープを絞り、「防御的コーディングの量」のような統計的・曖昧な指標は採用しません。

### 2.3 依存関係の楽観性（hallucination）

これが5つの中で最も構文解析だけでは対処が難しい問題です。

- **原理的にできないこと**: 「このユニット・この関数は実在するか」を一般的に判定すること。tree-sitter-pascal はシンボルテーブルも型情報も持たず、rawpaco自身もネットワーク越しのパッケージレジストリ照会は行いません（オフラインでも動くツールであるべき、というCI用途からの要請とも合致します）。
- **実際に多くのケースは既にCIの `make`（`fpc` によるコンパイル）で捕捉される**: 存在しない識別子・引数の型不一致は、コンパイルエラーとしてCIが既に検知しています。したがって rawpaco が担うべきなのは「コンパイルは通るが、実在するAPIの中から明後日の方向のものを選んでいる」ような、コンパイラでは検知できないケースに絞るのが現実的です。
- **代替案（部分的に実現可能）**:
  1. **FPC標準ユニットのシンボル一覧をバンドルする**: pin している FPC バージョンの `fpc-source` から、`SysUtils`/`Classes` 等の主要ユニットが公開する識別子一覧を抽出し、`data/fpc-rtl-symbols.json` のような形でバージョン付きでリポジトリに同梱します（tree-sitter-pascalのバージョン固定方針＝CLAUDE.mdルール2と同じ発想）。対象コードの `declUses` から取得したユニット名が、このバンドル済みリストに載っている既知ユニットである場合に限り、`exprDot`（`SysUtils.Foo` 形式）や `uses` 経由で見える裸の識別子呼び出しが当該ユニットのシンボル一覧に存在するかを突き合わせます。一致しなければ「バンドルされたSysUtils/Classes等には存在しない識別子」として警告します。
     - この方式は **RTL/FCLの既知ユニットに限定**され、ユーザー定義の型・クラスや、サードパーティパッケージ（Indy, mORMot等）は対象外です（そもそもこれらのソースを同梱するのは非現実的）。「サードパーティAPIの引数名の思い違い」のような、依頼文で挙げられた具体例の中心的なケースは、この方式ではカバーできないことを明記しておきます。
     - スコープ解決を行わない以上、`uses` に複数ユニットがある場合の名前解決の優先順位（後方のユニットが前方を隠す等）は正確に再現できません。「`uses` されているいずれのユニットのシンボル一覧にも見当たらない」場合のみ警告する、片方向の緩い実装とし、誤検知の芽を摘みます。
     - シンボル一覧の抽出パイプライン（`fpc-source` のPascalソースをパースしてシンボル名を抜き出す）自体の設計、フォーマットの決定、名前解決の緩め方の設計は難易度が高いため **担当: Opus5**。
  2. **「よくある幻覚APIのブロックリスト」を手動で育てる**: 実際に観測された「もっともらしいが存在しないFPC API名」（例: `TStringHelper.Contains` を FPC で使えると誤認する、等）を小さなリストとして蓄積し、完全一致で検知する方式。メンテナンスコストは低いが網羅性も低い、現実的な妥協案です。（担当: Sonnet5。ただし初期リストに何を載せるかの判断は人間/Opusのレビューを推奨）
- 依頼文にある「マイナーなライブラリやAPIの細かい引数名」レベルの誤りは、型・引数リスト解決が必須であり、本設計のスコープでは**検知できません**と明記します。

### 2.4 セキュリティ考慮漏れ

- 依頼文の例示（IAMポリシーの広さ）は、クラウドインフラ定義（IaC）を対象とした例であり、デスクトップ/サーバサイドPascalコードにはそのまま適用できません。Pascalの文脈で構文的に安全に検知できる代替パターンとして、以下2つに絞ります。
  1. **SQL文字列連結パターン**: `exprBinary` で `operator` が `+`（文字列連結）、`lhs`/`rhs` の一方が `literalString` でSQLキーワード（`SELECT`/`INSERT`/`UPDATE`/`DELETE`/`WHERE`/`FROM` 等、大文字小文字を無視）を含み、もう一方が `literalString` 以外（つまり変数や式）である場合に警告します。これは他言語向けの静的解析ツール（例: BanditのB608）でも採用されている実績のあるヒューリスティックです。パラメータ化クエリ（`Params.ParamByName(...).AsString := X` のような形）は連結を伴わないため誤検知しません。
  2. **シークレットらしき文字列のハードコード**: `varDef`/`declVar`/`declConst`/`assignment` の左辺識別子名が `password`/`secret`/`apikey`/`api_key`/`token`/`connectionstring` 等のパターン（大文字小文字無視、部分一致）にマッチし、右辺が空でない `literalString` である場合に警告します。`CHANGE_ME`/`YOUR_API_KEY_HERE`/空文字列のような明らかなプレースホルダは除外し、誤検知を抑えます（除外パターンは初期実装では固定の短いリストとし、将来設定ファイルで追加可能にする余地を残す）。
  3. **例外の握りつぶし**（2.2で既出）もセキュリティ観点（異常の隠蔽）から二重に位置づけられます。カテゴリとしては `RAWPACO-DEFENSE-*` を主としつつ、設計書上はセキュリティの一側面としても扱います。

### 2.5 古い書き方（学習データに引っ張られた非推奨API等）

- CLAUDE.md ルール1自体が、rawpaco開発時のこの問題への対処（freepascal.orgでの事前確認）になっていますが、ここでは**rawpacoが解析する対象コード側**の古い書き方を検知する話です。
- FPCのRTL/FCLソースは、非推奨の識別子に `deprecated;` または `deprecated 'メッセージ';` という言語標準のディレクティブを付与していることが多く、tree-sitter-pascalの文法にも `kDeprecated` トークンが存在します（`node-types.json` で確認済み）。これを利用し、2.3のRTLシンボル抽出パイプラインを拡張して「`deprecated` 付きの識別子一覧」も同時に抽出し、対象コードがそれらを呼び出している場合に警告する、という設計が自然です。抽出元となる `fpc-source` パッケージのバージョンは、CI環境のFPCバージョンと一致させ、pin方針（CLAUDE.mdルール2に準じる発想）で管理します。
- 対象コード自身が宣言した手続き・関数に `deprecated` を付けているのに、同一ファイル内で普通に呼び出し続けているケース（自己矛盾）は、追加のシンボル抽出なしに構文木だけで検知できます（`declProc` の `attribute` に `procAttribute` 経由で `kDeprecated` があるかを見て、その識別子名を同一ファイル内の `exprCall` の `entity` と突き合わせるだけ）。これは低コストで実装できる副産物です。
- 「最新のベストプラクティス」（例: 新しいFPCバージョンで追加された、より安全な代替APIがあるという情報）は、非推奨マークが付いていないケースでは検知できません（deprecatedディレクティブが付与されていない「暗黙的に古い」書き方は対象外）。

### 2.6 まとめ表

| # | 問題点 | 構文解析だけで検知できるか | 採用する代替・スコープ |
|---|---|---|---|
| 1 | 一貫性のムラ | 命名規則は○（要設定ファイル）。エラーハンドリングの意味的一貫性は×（ファイル内・表面API一致に限定した近似のみ） | 2.1参照 |
| 2 | 過剰な防御的コーディング | 「量」の判定は×。特定の無意味パターン（空except、生成直後nilチェック）は○ | 2.2参照 |
| 3 | hallucination | 一般的な実在確認は×（型・レジストリ情報が必要）。RTL/FCLの既知シンボルとの突き合わせは部分的に○ | 2.3参照。サードパーティAPIは対象外 |
| 4 | セキュリティ考慮漏れ | 依頼例（IAM）はPascalに非該当。SQL連結・シークレット直書きは○ | 2.4参照 |
| 5 | 古い書き方 | `deprecated` マーク付きAPIの使用は○。マークなしの暗黙的な古さは× | 2.5参照 |

## 3. positive/negativeサンプルの配置・実行方法

CLAUDE.mdルール3（positive/negative両方必須）との整合のため、以下の規約とします（`tests/README.md` にも要点を追記済み）。

- 配置: `tests/positive/<RuleId>/*.pas`、`tests/negative/<RuleId>/*.pas`。1ルールにつき複数ファイル可（バリエーションごとに増やす）。
- 実行方法: `tests/run_tests.sh`（新設）を用意し、以下を行う。
  1. `tests/negative/<RuleId>/` の各 `.pas` について `./src/rawpaco <file>` を実行し、出力に `<RuleId>` が含まれることを確認する（含まれなければテスト失敗）。
  2. `tests/positive/<RuleId>/` の各 `.pas` について同様に実行し、出力に `<RuleId>` が**含まれないこと**を確認する（含まれればテスト失敗＝誤検知）。
  3. `Makefile` に `test` ターゲットを追加し `make test` で一括実行できるようにする。CI（`.github/workflows/ci.yml`）の `build-linux`/`build-windows` 双方に `make test`（またはWindows側は対応するシェルコマンド）のステップを追加する。
- シェルスクリプトを選ぶ理由: FPC用の単体テストフレームワーク（fpcunit等）を導入する選択肢もありますが、rawpaco自体がCLIとして完結しており、入出力（終了コード・標準出力の文字列マッチ）で十分検証できるため、依存を増やさずCI上のbashで完結する方式を採ります。将来ルール数が増えてアサーションが複雑化した場合はfpcunit移行を検討してよい、という含みを残します。（担当: Sonnet5）

## 4. 診断結果の出力形式

**実装状況の注記（2026-08-04、実装済み）**: 本節で設計した `--format` オプション・`github`/`json` 出力・「インライン抑制コメント」（`// rawpaco:ignore`）はいずれも実装済み。フォーマッタは `src/Diagnostics.pas`（`FormatDiagnosticText`/`FormatDiagnosticGithub`/`FormatDiagnosticsJson`）、`--format` の解析・検証は `Diagnostics.ParseOutputFormat`、`src/LintDriver.pas` の `RunLint` は全入力ファイル分の診断を1つのリストに集約してから（`json`形式が単一の配列を出す必要があるため）抑制フィルタと整形を通す構成にした。回帰テストは `tests/run_tests.sh` の `format_case`/`suppression_case`、フィクスチャは `tests/suppression/` を参照。

GitHub Actions上での利用を主眼に、以下の3形式をサポートします（`--format` オプション、デフォルトは `text`）。

- `text`（デフォルト、人間可読）: `<ファイル名>:<行>:<列>: warning: <メッセージ> [<RuleId>]`（gcc/eslint系に倣った形式）
- `github`: GitHub Actions のワークフローコマンド形式 `::warning file=<ファイル名>,line=<行>,col=<列>::[<RuleId>] <メッセージ>` を1行ずつ出力する。これによりPRの差分表示に直接インライン注釈が付く。
- `json`: `[{"ruleId":..,"file":..,"line":..,"column":..,"severity":..,"message":..}, ...]` の配列。他ツールとの連携・将来のGitHub Annotations API連携等を見込んだ機械可読形式。

**終了コード**: 重要度による段階制御・既定は寛容。詳細は4.1節。従来の「診断1件でも終了コード1」という契約は、そこで説明する`--fail-on=warning`（俗称「激辛モード」）を明示指定した場合の挙動としてのみ残る。

### 4.1 重要度別の終了コード制御: 導入で決着、既定は寛容（2026-08-04改訂、担当: Fable5）

**このセクションは英語版が正であり、日本語訳は要約のみです。詳細な根拠・per-ruleの重要度表・CLI仕様は英語版 [docs/RULE_ENGINE_DESIGN.md](RULE_ENGINE_DESIGN.md) の4.1節を参照してください。**

このセクションは改訂版です。当初（Fable5の1回目のレビュー）は「実装済み9ルールがいずれもfpc-source全体で誤検知ゼロまでチューニングされている」という実測に基づき「導入しない」で決着していましたが、プロジェクトオーナーがこの結論にレビューで異議を唱えました。オーナーは実測データそのものは正しいと認めた上で、「rawpacoが自分自身をlintする際の無妥協な方針（自己lint）はrawpaco自身にとって正しいが、rawpacoは採用障壁を下げる必要のある新規ツールであり、下流の利用プロジェクトはそれぞれ異なるCI方針を持つ」という枠組みの違いを指摘しました。この指摘を受け入れ、結論を「導入する、ただし既定は寛容（error段階のみが既定でビルドを落とす）、`--fail-on=warning`（激辛モード）で従来どおりの無妥協な挙動に明示的に切り替え可能」に改めました。

要点（詳細は英語版参照）:

- `TSeverity`に`svError`を追加（`svWarning`との2段階）。各ルールが`CSeverity`定数として自ら宣言し、`IRawpacoRule.Severity`で問い合わせ可能にする。CLIからの上書きは設けない(ルール自身の性質として固定)。
- 重要度は「検知精度への自信」ではなく「対応しない場合の結果の深刻さ」で決める。実装済み9ルールの内訳: **Error**=RAWPACO-DEFENSE-001・SEC-001・SEC-002・HALLUC-001（握りつぶし・SQLインジェクション・ハードコードされた秘密情報・実在しないRTLシンボル参照という、いずれも「今すぐ対応すべき具体的な欠陥」カテゴリ）。**Warning**=RAWPACO-DEPR-001・DEPR-002・STYLE-001・DEFENSE-002・STYLE-002（非推奨API・命名規則・冗長なnilチェック・エラーハンドリング不統一の近似検知という、いずれも「いずれ直すべきだが今すぐビルドを止めるほどではない」カテゴリ）。
- CLIは`--fail-on=error|warning`（既定`error`）を新設。`--fail-on=warning`が「激辛モード」で、既存の全診断でビルドを落とす挙動を厳密に再現する。未知の値は`--format=`と同じ方針でエラー終了。
- **自己lintは既定の寛容な挙動に頼らず、明示的に`--fail-on=warning`を渡すことで従来どおりの無妥協な方針を維持する。** `Makefile`の`selflint`ターゲット（現状 `./src/rawpaco src/*.pas src/Rules/*.pas src/rawpaco.lpr`）は、この機能導入と同じ変更の中で`--fail-on=warning`を追加する必要があると明記した（このセクションでは`Makefile`自体は編集していない）。これを怠ると、既定変更と同時に9ルール中5ルールが自己lintのCIゲートを静かに素通りするようになる。
- `text`/`github`/`json`のいずれの形式でも、`--fail-on`の値に関わらず重要度は常に表示する(warning扱いのルールが「発火しても見えない」ことには絶対にならない)。`github`形式は`::error`/`::warning`をそのまま出し分けられるようになる。
- 1回目のレビューで指摘した懸念（「重要度層があると、チューニングが難しいルールをWarningとして安易に出荷する抜け道になる」）は今回の枠組み変更でも消えないため、明示的なガードを設けた: 重要度は「対応の緊急度」だけを表し、「検知精度への自信」を代替してはならない。誤検知ゼロの基準（CLAUDE.mdルール5、6節の基準）を満たさないルールは、重要度に関わらずそもそも出荷しない。
- 既定挙動の変更は意図的な破壊的変更であり、`0.0.1-dev`で外部利用者がまだいない今のタイミングだからこそ許容されると明記した。

**インライン抑制コメント**: 個別の誤検知・意図的な例外に対応するため、対象行または直前行に `// rawpaco:ignore <RuleId>` があれば、その行に関するその `RuleId` の診断を抑制します。false positiveをゼロにはできない前提（CLAUDE.mdルール5はあくまで「回避を優先する」であり保証ではない）に立ち、CIをブロックするツールとして運用可能にするための逃げ道として必須と判断しました。抑制コメントを使う場合は「なぜ抑制するか」のコメントも併記することを推奨する運用ルールとし、これは将来 `README.md`/`CLAUDE.md` に追記を検討してよい項目です（本設計書では提案に留める）。（担当: Sonnet5）

実装メモ: `TDiagnostic` が持つ行・列はtree-sitterの`TSPoint.row`由来だが、`vendor/tree-sitter/src/lexer.c`の`ts_lexer__do_advance`を確認すると`'\n'`バイトの出現でのみ行が進み、`'\r'`単体では進まない。`Diagnostics.SplitSourceLines`はCR/LF/CRLFいずれも改行として扱う汎用的な行分割ではなく、`'\n'`のみで自前分割することで、抑制コメントの行番号照合をtree-sitter自身の行番号基準と一致させている（CLAUDE.mdルール1: 想定ではなくvendor配下の実装そのもので照合する）。

## 5. 自己lint組み込みへの道筋（鶏卵問題）

CLAUDE.mdルール4「本ツール自身のソースをlintし警告ゼロを維持するCIステップを追加する」は、ルールが1つも無い現状ではCIに追加しようがありません（HANDOFF.mdの現状記載どおり）。以下の順序で解消します。

1. ルール第1号（7節の優先順位に従う）を実装し、positive/negativeサンプルで動作確認する。
2. **ローカルで** `./src/rawpaco src/*.pas` を実行し、rawpaco自身のソースに対して誤検知・真陽性がないか確認する。
   - 真陽性（本当に直すべき箇所）が見つかった場合は、CLAUDE.mdルール8に従い理由コメントを残しつつ修正する。
   - 誤検知の場合はルール自体のロジックを見直す（安易に4節の抑制コメントで揉み消さない。抑制コメントは「意図的な例外」のためのものであり、ルールのバグを隠すためのものではない）。
3. 手順2でクリーンになったことを確認できたルールから順に、CI（`.github/workflows/ci.yml`）の `build-linux`/`build-windows` 両ジョブに「自身のソースをlintし、終了コードが0であることを確認する」ステップを追加する。1ルールも無い状態から全ルール分をまとめて待つ必要はなく、クリーンになったルールから漸進的に自己lint対象に加えてよい（例えば `rawpaco --only=RAWPACO-SEC-001 src/*.pas` のような特定ルールのみ有効化するオプションを用意し、自己lintの対象範囲を明示的にコントロールする）。
4. 全ルールが自己lintをクリアした段階で `--only` 指定を外し、フルセットでの自己lintに移行する。
5. HANDOFF.mdの「自己lint到達状況」セクションを、各ステップの進捗に合わせて都度更新する。

`--only`/`--exclude` オプションはこの漸進導入のために必須と判断し、7節のルール実装と合わせて早期に用意することを推奨します。（担当: Sonnet5）

## 6. 実装優先順位と最初の数個のルール具体案

false positive回避のしやすさ・実装の単純さ・価値の高さで優先順位付けしました。P1〜P3は構文パターンのみで完結し高い確度で安全、P4以降は設定ファイルやデータパイプラインなど追加の設計要素を要します。

### P1: RAWPACO-DEFENSE-001 空のexceptハンドラ（例外の握りつぶし）

- 検知対象: `exceptionHandler`/`exceptionElse` の本体が実質空（`;` のみ、または子ノードが無い）。
- 該当する問題点: 2番目（過剰防御）と4番目（セキュリティ・異常の隠蔽）の両方。
- 誤検知リスク: 低い（意図的にログ出力すらしない空catchは、ほぼ常に見直すべきコード）。
- 担当: Sonnet5

### P2: RAWPACO-SEC-001 SQL文字列連結パターン

- 検知対象: 2.4節1参照。`exprBinary` の `+` 演算子で片側がSQLキーワードを含む `literalString`、もう片側が非リテラル。
- 誤検知リスク: 中程度（SQLに見えるが実際はログメッセージ等の文字列連結を拾う可能性）。キーワードは行頭または単語境界での一致に限定し、`WHERE`/`SELECT`等の一般的すぎない語のみを対象にする等のチューニングが要る。
- 担当: Sonnet5

### P3: RAWPACO-SEC-002 シークレットらしき文字列のハードコード

- 検知対象: 2.4節2参照。
- 誤検知リスク: 中程度（プレースホルダ除外リストのチューニングが必要）。
- 担当: Sonnet5

### P4: RAWPACO-DEPR-001 自己矛盾する非推奨API使用（同一ファイル内）

- 検知対象: 2.5節の「対象コード自身が宣言した`deprecated`手続きを同一ファイル内で呼び続けている」ケース。外部データ不要で構文木のみで完結する。
- 誤検知リスク: 低い。
- 担当: Sonnet5

### P5: RAWPACO-STYLE-001 命名規則チェック（設定ファイルベース）

- 検知対象: 2.1節参照。型名の `T` プレフィックス、フィールドの `F` プレフィックス等。
- 難しい点: 「規則をどう表現するか」（正規表現ベースか、プレフィックス/サフィックスの宣言的な指定か）、規則が指定されていないプロジェクトでのデフォルト値をどうするか、FPC/Lazarusコミュニティで広く合意されている規則とそうでない規則の線引きなど、曖昧な仕様判断を伴う。
- 担当: **Opus5**（設定ファイルのスキーマ設計とデフォルト規則の選定。スキーマ確定後の機械的なAST照合部分はSonnet5でも実装可能）

### P6: RAWPACO-DEPR-002 FPC RTL/FCLの`deprecated`シンボル一覧に基づく検知

- 検知対象: 2.5節。`fpc-source` からの `deprecated` 識別子抽出パイプラインが前提。
- 難しい点: 抽出パイプライン自体の設計（Pascalソースの簡易パース、対象ユニットの選定、バージョン管理・再生成手順、既存ルールへの影響確認をどう回すか）。
- 担当: **Opus5**

### P7: RAWPACO-HALLUC-001 FPC RTL/FCLの既知シンボル一覧との突き合わせ

- 検知対象: 2.3節の代替案1。
- 難しい点: シンボル一覧抽出パイプライン（P6と共有可能）に加え、`uses`節に基づく片方向の緩い名前解決ロジックの設計。
- 担当: **Opus5**

### P8: RAWPACO-DEFENSE-002 生成直後の無意味なnilチェック

- 検知対象: 2.2節参照。
- 誤検知リスク: 「直後」の範囲定義次第で変わる。最初は同一`statements`内で直接後続の文のみを対象にする狭いスコープから始める。
- 担当: Sonnet5

### P9: RAWPACO-STYLE-002 同一ファイル内でのエラーハンドリング不統一（近似）

- 検知対象: 2.1節の「緩い近似」案（同種API呼び出しがtry保護されている箇所とされていない箇所の混在）。
- 難しい点: 「同種API呼び出し」をどう定義するか（呼び出し名の完全一致に留めるか、`declUses`から見える特定ユニット由来の呼び出しに絞るか等）、および誤検知率の見積もり。
- 担当: **Opus5**

## 7. 未決事項・提案（大きな方針転換になりうるもの・独断で決めていない事項）

以下は本レビューで気づいたものの、既存ルールの削除やスコープの大幅変更に相当するため、提案に留め、断行していません。

- **セッション（コミット履歴）を跨いだ命名規則・慣習ドリフトの検知**: 2.1節で述べた通り、単一ファイルの構文解析では原理的に扱えません。`git log`/`git blame`との連携や、複数ファイル・複数コミットにまたがる集計を行う「rawpaco拡張モード」を将来検討する余地はありますが、これは「静的解析ツール」から「リポジトリ解析ツール」への性格変化を伴うため、着手する場合は改めて設計判断が必要です。
- ~~**重要度別（warning/error）の終了コード制御**~~: 決着済み、4.1節参照（担当: Fable5、プロジェクトオーナーのレビューを受けて改訂）。結論: **導入する**。既定は寛容（Error段階のみが既定でビルドを落とす）、`--fail-on=warning`（激辛モード）で従来どおりの無妥協な挙動を明示的に選択可能。自己lintは`--fail-on=warning`を明示的に使うことで従来方針を維持する。
- **抑制コメント運用ルールのCLAUDE.md/README.mdへの明文化**: 4節で触れた「抑制コメントには理由を書く」という運用ルールは、CLAUDE.mdルール8（コメントは「なぜ」を残す）の精神に沿うものですが、CLAUDE.md自体への追記はルールの新設に相当するため、本セッションでは行わず提案に留めました。
- **CLAUDE.mdルール1の適用範囲を「外部Cライブラリ全般」に広げる編集**（本セッションで実施済みの小修正とは別に、より踏み込んだ一般化）: 本セッションでは「tree-sitterのAPIも対象に含める」という最小限の明確化のみ行いました。将来、他の外部Cライブラリを追加する可能性が出てきた場合は、ルール文言をより一般化することを検討してください。

## 8. 担当振り分け一覧（まとめ）

| 項目 | 担当 |
|---|---|
| ASTWalker（走査ドライバ） | Sonnet5 |
| TSBindings.pas 拡張（ノード走査系関数の追加） | Sonnet5 |
| RuleRegistry・ルールインターフェース定義 | Sonnet5 |
| Diagnostics（TDiagnostic、出力フォーマッタ text/github/json） | Sonnet5 |
| 抑制コメント（`rawpaco:ignore`）機構 | Sonnet5 |
| tests/run_tests.sh・Makefile `test`ターゲット | Sonnet5 |
| `--only`/`--exclude` オプション | Sonnet5 |
| P1 RAWPACO-DEFENSE-001（空except） | Sonnet5 |
| P2 RAWPACO-SEC-001（SQL文字列連結） | Sonnet5 |
| P3 RAWPACO-SEC-002（シークレット直書き） | Sonnet5 |
| P4 RAWPACO-DEPR-001（自己矛盾deprecated使用） | Sonnet5 |
| P5 RAWPACO-STYLE-001（命名規則、設定ファイルスキーマ） | **Opus5**（スキーマ・デフォルト規則） / Sonnet5（スキーマ確定後のAST照合実装） |
| P6 RAWPACO-DEPR-002（RTL deprecatedシンボル抽出） | **Opus5** |
| P7 RAWPACO-HALLUC-001（RTLシンボル突き合わせhallucination検知） | **Opus5** |
| P8 RAWPACO-DEFENSE-002（生成直後nilチェック） | Sonnet5 |
| P9 RAWPACO-STYLE-002（エラーハンドリング不統一の近似検知） | **Opus5** |
