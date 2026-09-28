unit RuleMode001;

{$mode objfpc}{$H+}

// RAWPACO-MODE-001: `string` が ShortString になる状態のまま `string` を使っている
// ことの検知（255文字での黙った切り捨て）。docs/RULE_ENGINE_DESIGN.md 2.7節/P10。
//
// ■ なぜこれを検知するのか（コンパイラが何も言わない実害）
//
// `{$mode objfpc}` は `{$H+}` を**含意しない**。つまり `{$mode objfpc}` だけを
// 書いて `{$H+}` を忘れると、`string` は ShortString（最大255文字）のままになり、
// 256文字以上を代入すると**警告もヒントも一切出ないまま黙って切り捨てられる**。
// fpc 3.2.2 での実測（`var S: string; S := StringOfChar('x', 300)` の Length）:
//
//   {$mode objfpc}{$H+}  -> 300
//   {$mode objfpc}       -> 255   ★これ
//   {$mode fpc} / {$mode tp} / {$mode macpas} -> 255
//   {$mode delphi}       -> 300   (delphi 系だけが $H+ を含意する)
//   {$H+}{$mode objfpc}  -> 255   ★{$mode} が $H を既定値に戻すため順序が効く
//
// Lazarus が生成する全てのユニットが `{$mode objfpc}{$H+}` と対で書いているのは
// このためで、AI が書いた FPC コードでは `{$H+}` だけが落ちることが実際にある。
// コンパイラは何も言わないので、CI のビルドを通ってしまう。
//
// なお ★2行目のとおり `{$H+}` を `{$mode}` より前に置くと無効になる。
// 「ファイル内に `{$mode objfpc}` と `{$H+}` の両方があるか」という集合判定では
// この形を取りこぼすため、指令はソース順の状態機械として畳み込む
// （`src/CompilerDirectives.pas` がその収集と解析を担う）。
//
// ■ 検知条件
//
// (1) root 直下に `unit`/`program`/`library` がある（`ASTHelpers.IsCompilationUnit`）
// (2) ファイル内に `{$mode }` 指令が1つ以上ある
// (3) `string` キーワードによる宣言（`declString` ノード）が1つ以上ある
// (4) 最初の `declString` の位置における `$H` の状態がオフ
//
// 報告は「最初の `declString`」1箇所のみ。同じ原因で何十箇所も報告しても
// 情報が増えないため。
//
// ■ 誤検知回避のための門番（いずれも CLAUDE.mdルール5: 疑わしきは見逃す）
//
// (a) **`{$I }` / `{$INCLUDE }` を含むファイルは対象外。** `$H` 指令が include 先に
//     置かれている実例がある（fpc-source の `compiler/fpcdefs.inc` の3行目が
//     まさに `{$H-}`で、`compiler/*.pas` はこれを include して意図的に
//     ShortString で書かれている）。tree-sitter は include を展開しないので、
//     「このファイルに `{$H+}` が無い」ことは「`$H` がオフ」を意味しない。
// (b) **`{$mode}` / `$H` 指令が条件コンパイルブロックの中にあるファイルは対象外。**
//     `{$ifdef FPC}{$mode objfpc}{$H+}{$endif}` は Delphi 互換のための定型で、
//     どの枝が有効かはビルド構成次第のため判定できない。
// (c) **`{$mode}` が1つも無いファイルは対象外。** 既定のモードはコマンドライン
//     (`-Mobjfpc`) や `fpc.cfg` で決まり、ソースからは分からない。Lazarus の
//     プロジェクトはモードをプロジェクト側で指定することもある。
// (d) **未知のモード名（`IsKnownModeName` が False）が現れたら対象外。**
//     rawpaco が知らない方言の `$H` 既定値は推測できない。
// (e) **構文エラーを含むファイル（`ts_node_has_error`）は対象外。** 指令の
//     位置関係と `declString` の位置関係が信用できない。
//
// ■ 意図的に ShortString を使っているコードについて
//
// (a) の include 門番で fpc-source の `compiler/` 配下（`{$H-}` を include で
// 共有している最大の集団）は自然に外れる。それでも「意図して `{$mode objfpc}`
// のまま ShortString を使っている」コードは残りうるため、重要度は Warning とし、
// 既定では CI を落とさない。抑制したい場合は `// rawpaco:ignore
// RAWPACO-MODE-001` か、明示的に `ShortString` と書くことで意図を示せる。
//
// ■ tree-sitter-pascal(v0.10.2) の実際の文法（プローブで実機確認）
//
// - `var S: string;` は `declVar` > `[type] type` > **`declString`** > `kString`。
//   `AnsiString`/`ShortString` のような型名は `typeref` > `identifier` になるため
//   `declString` には**ならない**。つまり `declString` は「`string` キーワードを
//   書いた箇所」を指す。
// - `declString` になるのは、変数宣言(`declVar`)・フィールド・**手続き引数
//   (`declArg`)**・**型エイリアス(`declType`: `TAlias = string`)**・
//   **`array of string`** のいずれも含む（プローブで実測）。
// - **唯一の例外が関数の戻り値型**で、`function F: string;` の `string` は
//   `declProc` の `[type] typeref` > `identifier "string"` になり `declString`
//   には**ならない**（実測。これを見落として最初の実装は
//   `function Describe: string` を検知できなかった）。そのため、
//   `string` という綴りの `identifier` ノードも検知対象に含める。
//   これが安全なのは、`string` が FPC の予約語であり変数名・型名として
//   使えないため、`identifier` として現れる `string` は必ず型としての
//   `string` であることによる（文字列リテラルは `literalString`、コメントは
//   `comment` という別ノード種別なので取り違えない）。

interface

uses
  SysUtils, Generics.Collections, TSBindings, Diagnostics, RuleRegistry;

type
  TRuleMode001 = class(TInterfacedObject, IRawpacoRule)
  public
    function RuleId: string;
    function Description: string;
    function Severity: TSeverity;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

implementation

uses
  ASTHelpers, CompilerDirectives;

const
  CRuleId = 'RAWPACO-MODE-001';
  // 設計書4.1.2節の基準は「対応しなかった場合の結果の深刻さ」。256文字以上の
  // 文字列が黙って切り捨てられるのは深刻だが、ShortString を意図して使って
  // いるコードも存在しうる（上記「意図的に ShortString を使っているコード」）。
  // 検知精度への自信ではなく「意図的な選択でもありうる」という性質のため、
  // 既定ではCIを落とさないWarning階層とする。
  CSeverity = svWarning;

// そのノードが「`string` キーワードを書いた箇所」か。
// `declString` に加えて、関数の戻り値型として現れる `identifier "string"` も
// 対象にする（ユニット冒頭コメントの文法メモ参照）。
function IsStringKeywordNode(const Node: TSNode; Ctx: TLintContext): Boolean;
var
  NodeType: PAnsiChar;
begin
  NodeType := ts_node_type(Node);
  Result := (NodeType = 'declString') or
            ((NodeType = 'identifier') and
             (LowerCase(Ctx.GetNodeText(Node)) = 'string'));
end;

// 部分木の中で最も早い位置に現れる「`string` キーワードの箇所」を返す。
function TryFindFirstDeclString(const Node: TSNode; Ctx: TLintContext;
  out Found: TSNode): Boolean;
var
  Count, I: LongWord;
  Child: TSNode;
  ChildFound: TSNode;
begin
  if IsStringKeywordNode(Node, Ctx) then
  begin
    Found := Node;
    Exit(True);
  end;

  Result := False;
  Found := Node; // ダミー初期値
  Count := ts_node_named_child_count(Node);
  I := 0;
  while I < Count do
  begin
    Child := ts_node_named_child(Node, I);
    if TryFindFirstDeclString(Child, Ctx, ChildFound) then
    begin
      // 走査順は行きがけなので最初に見つかったものが最も早い位置にあるが、
      // 順序がこのルールの判定（指令との前後関係）の根幹なので、
      // 走査順に依存せず開始バイトで比べる。
      if (not Result) or (ts_node_start_byte(ChildFound) < ts_node_start_byte(Found)) then
      begin
        Found := ChildFound;
        Result := True;
      end;
    end;
    Inc(I);
  end;
end;

function TRuleMode001.RuleId: string;
begin
  Result := CRuleId;
end;

function TRuleMode001.Severity: TSeverity;
begin
  Result := CSeverity;
end;

function TRuleMode001.Description: string;
begin
  Result := '"string" is a ShortString here because {$H+} is not in effect (silent truncation at 255 chars)';
end;

function TRuleMode001.InterestedNodeTypes: TStringArray;
begin
  // ファイル単位の判定（指令の並びと declString の位置関係）なので root のみ。
  // RuleDepr001 と同じ理由で、ルールインスタンスに状態を持たせない。
  Result := TStringArray.Create('root');
end;

procedure TRuleMode001.Check(const Node: TSNode; Ctx: TLintContext);
var
  Directives: TDirectiveList;
  D: TDirective;
  I: Integer;
  StrNode: TSNode;
  LongStringsOn, SawMode: Boolean;
  LastMode: string;
begin
  if ts_node_has_error(Node) then Exit;          // 門番(e)
  if not IsCompilationUnit(Node) then Exit;      // 門番(1)
  if not TryFindFirstDeclString(Node, Ctx, StrNode) then Exit; // 条件(3)

  Directives := TDirectiveList.Create;
  try
    CollectDirectives(Node, Ctx, Directives);

    for I := 0 to Directives.Count - 1 do
    begin
      D := Directives[I];
      if D.Kind = dkInclude then Exit;           // 門番(a)
      if (D.CondDepth > 0) and
         ((D.Kind = dkMode) or (D.Kind = dkLongStrings)) then
        Exit;                                    // 門番(b)
      if (D.Kind = dkMode) and not IsKnownModeName(D.Arg) then
        Exit;                                    // 門番(d)
    end;

    // 最初の declString の位置まで指令をソース順に畳み込む。
    LongStringsOn := False;
    SawMode := False;
    LastMode := '';
    for I := 0 to Directives.Count - 1 do
    begin
      D := Directives[I];
      if D.StartByte >= ts_node_start_byte(StrNode) then Break;
      case D.Kind of
        dkMode:
          begin
            SawMode := True;
            LastMode := D.Arg;
            // {$mode} は $H をそのモードの既定値に戻す（実測）。
            LongStringsOn := ModeImpliesLongStrings(D.Arg);
          end;
        dkLongStrings:
          LongStringsOn := (D.Arg = '+');
      else
        ; // 関心のない指令
      end;
    end;

    if not SawMode then Exit;                    // 門番(c)
    if LongStringsOn then Exit;

    Ctx.Report(CRuleId, CSeverity,
      Format('"string" here is a ShortString (truncated at 255 chars) because ' +
             '{$H+} is not in effect after {$mode %s}; add {$H+} right after the ' +
             '{$mode} directive (as Lazarus does), or write ShortString/AnsiString explicitly',
             [LastMode]),
      StrNode);
  finally
    Directives.Free;
  end;
end;

initialization
  RegisterRule(TRuleMode001.Create);

end.
