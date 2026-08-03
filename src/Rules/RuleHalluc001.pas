unit RuleHalluc001;

{$mode objfpc}{$H+}

// RAWPACO-HALLUC-001: FPC の RTL/FCL に実在しない識別子（hallucination）の検知。
// docs/RULE_ENGINE_DESIGN.md P7/2.3節に対応。データ源は RAWPACO-DEPR-002 と共有
// （data/fpc-rtl-symbols.txt / src/FPCSymbols.pas）。
//
// 設計書 2.3 は「uses されているいずれのユニットのシンボル一覧にも見当たらない
// 識別子を警告する」と書いているが、その通りに実装すると**ローカル変数も自前の
// 型も全部警告される**（rawpaco は型解決もスコープ解決もできないので、
// 「Foo という識別子」がユーザ定義なのか RTL 由来なのか自体を区別できない）。
// そのため、確実に判定できる2つの形にだけ絞る。
//
// ■ 判定A: ユニット修飾された参照 `SomeUnit.Foo`
//   lhs が「そのファイルの uses に現れ、かつ data/ に strict として載っている
//   ユニット名」である exprDot に限り、rhs がそのユニットのシンボル一覧に
//   無ければ報告する。ユニット名で修飾されている以上、その名前はそのユニットの
//   ものでなければならないので、スコープ解決なしで安全に判定できる。
//
// ■ 判定B: 修飾なしの呼び出し `Foo(...)`
//   「そのファイルが uses しているユニットが全て data/ に載っている既知ユニット
//   である」場合に限り有効にする。この条件が成り立つとき、呼び出せる名前は
//   「そのファイル自身が宣言したもの」か「既知ユニットが公開しているもの」か
//   「System の組み込み」しかありえない。どれにも無ければ実在しない名前である。
//   逆に uses に1つでも未知のユニット（LCL、サードパーティ、プラットフォーム
//   専用ユニット等）があれば、その中に定義があるかもしれないので判定Bは
//   丸ごと無効にする。
//
// 判定Bを成立させるための門番（いずれも CLAUDE.mdルール5: 疑わしきは見逃す）:
//   - 構文エラーを含むファイル（ts_node_has_error）では木の形が信用できないので
//     判定A・Bとも行わない。
//   - `{$I xxx.inc}` / `{$INCLUDE ...}` を含むファイルでは、include 先の宣言が
//     構文木に現れないため「ファイル内で宣言されていない」判定が成立しない。
//     判定Bを無効にする。
//   - `with Rec do ... end` の本体は、裸の名前がレコード/オブジェクトのメンバを
//     指しうるので走査しない（RAWPACO-DEPR-002 で実測した誤検知要因と同じ）。
//   - `inherited Foo` は継承元のメソッド名であり、修飾なし呼び出しではない。
//   - クラスの継承メソッドは、継承元が既知ユニットのクラスなら data/ 側の
//     M 行（ユニットレベル以外の既知の名前。クラスメンバを含む）に載っているため
//     未知扱いにはならない。
//
// tree-sitter-pascal(v0.10.2) の実際の文法（プローブプログラムで実機確認済み）:
//   - 括弧付き呼び出しは `exprCall`（フィールド `entity` / `args`）。
//     `SysUtils.Format(...)` のような修飾付きは entity が `exprDot` になる。
//   - `inherited Go;` は `inherited` ノード（`kInherited` + `identifier`）で、
//     `exprCall` にはならない。
//   - `with` は `with` ノード（フィールド `entity` / `body`）。

interface

uses
  SysUtils, Generics.Collections, TSBindings, Diagnostics, RuleRegistry;

type
  TRuleHalluc001 = class(TInterfacedObject, IRawpacoRule)
  public
    function RuleId: string;
    function Description: string;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

implementation

uses
  FPCSymbols;

const
  CRuleId = 'RAWPACO-HALLUC-001';

type
  TNameSet = specialize TDictionary<string, Boolean>;
  TUnitList = specialize TList<string>;

  THallucScan = class
  private
    FCtx: TLintContext;
    FUnits: TUnitList;        // uses に現れたユニット名（元の綴り）
    FDeclared: TNameSet;
    FUnqualifiedEnabled: Boolean;
    function IsDeclaredHere(const Name: string): Boolean;
    function KnownInAnyUsedUnit(const Name: string): Boolean;
    procedure CheckQualified(const Node: TSNode);
    procedure CheckUnqualifiedCall(const Node: TSNode);
  public
    procedure Walk(const Node: TSNode);
  end;

// ファイル内の全ての宣言名を集める（親ノードのフィールド名が `name` の identifier）。
// ジェネリック型 `generic TFoo<T> = class` の名前は `genericTpl` ノードになり
// identifier ではないため、`genericTpl` 配下の identifier（型名 T含む型引数）は
// まとめて拾う。多めに拾っても警告を抑制する方向にしか効かない。
procedure CollectDeclaredNames(const Node: TSNode; Ctx: TLintContext; Names: TNameSet);
var
  ChildCount, I, NamedCount, J: LongWord;
  Child: TSNode;
  FieldName: PAnsiChar;
  InGenericTpl: Boolean;
begin
  InGenericTpl := (ts_node_type(Node) = 'genericTpl') or (ts_node_type(Node) = 'genericArg');
  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    FieldName := ts_node_field_name_for_child(Node, I);
    if InGenericTpl or ((FieldName <> nil) and (FieldName = 'name')) then
    begin
      Child := ts_node_child(Node, I);
      if ts_node_type(Child) = 'identifier' then
        Names.AddOrSetValue(UpperCase(Ctx.GetNodeText(Child)), True);
    end;
    Inc(I);
  end;

  NamedCount := ts_node_named_child_count(Node);
  J := 0;
  while J < NamedCount do
  begin
    CollectDeclaredNames(ts_node_named_child(Node, J), Ctx, Names);
    Inc(J);
  end;
end;

procedure CollectUsedUnits(const Node: TSNode; Ctx: TLintContext; Units: TUnitList);
var
  NamedCount, J: LongWord;
  Child: TSNode;
begin
  if ts_node_type(Node) = 'declUses' then
  begin
    NamedCount := ts_node_named_child_count(Node);
    J := 0;
    while J < NamedCount do
    begin
      Child := ts_node_named_child(Node, J);
      if ts_node_type(Child) = 'moduleName' then
        Units.Add(Ctx.GetNodeText(Child));
      Inc(J);
    end;
    Exit;
  end;

  NamedCount := ts_node_named_child_count(Node);
  J := 0;
  while J < NamedCount do
  begin
    CollectUsedUnits(ts_node_named_child(Node, J), Ctx, Units);
    Inc(J);
  end;
end;

function FindFieldChild(const Node: TSNode; const FieldName: string; out Child: TSNode): Boolean;
var
  ChildCount, I: LongWord;
  F: PAnsiChar;
begin
  Result := False;
  Child := Node;
  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    F := ts_node_field_name_for_child(Node, I);
    if (F <> nil) and (F = FieldName) then
    begin
      Child := ts_node_child(Node, I);
      Exit(True);
    end;
    Inc(I);
  end;
end;

// 判定Bを無効にすべきコンパイラディレクティブを含むか。
//   - `{$I foo.inc}` / `{$INCLUDE foo.inc}`: include 先の宣言が構文木に
//     現れないため「ファイル内で宣言されていない」判定が成立しない。
//     `{$IFDEF}`/`{$IF }`/`{$I+}`（I/Oチェック）と取り違えないよう、
//     `{$I` の直後が空白の場合と `{$INCLUDE` の場合だけを include とみなす。
//   - `{$MACRO ON}`: `{$define Rsc := }` のようなマクロ展開が行われる。
//     tree-sitter はマクロを展開しないので、消える（あるいは別物に化ける）
//     識別子を実在しないものとして報告してしまう
//     （fpc-source の packages/palmunits がまさにこの書き方で、実測時に
//      175件の誤検知を出した）。
function HasDisablingDirective(const Source: AnsiString): Boolean;
var
  Upper: AnsiString;
begin
  Upper := UpperCase(Source);
  Result := (Pos('{$I ', Upper) > 0) or (Pos('{$INCLUDE', Upper) > 0) or
            (Pos('(*$I ', Upper) > 0) or (Pos('(*$INCLUDE', Upper) > 0) or
            (Pos('{$MACRO', Upper) > 0) or (Pos('(*$MACRO', Upper) > 0);
end;

// root 直下に unit / program / library があるか。
// FPC のソースには `{$i}` で他のファイルに取り込まれる前提の「断片」
// （unit ヘッダも uses も持たない .pp/.inc）が多数あり、それを単体で lint すると
// 宣言の大半が見えない状態で判定Bが動いてしまう。断片は判定Bの対象外とする。
function IsCompilationUnit(const Root: TSNode): Boolean;
var
  Count, I: LongWord;
  T: PAnsiChar;
begin
  Result := False;
  Count := ts_node_named_child_count(Root);
  I := 0;
  while I < Count do
  begin
    T := ts_node_type(ts_node_named_child(Root, I));
    if (T = 'unit') or (T = 'program') or (T = 'library') then
      Exit(True);
    Inc(I);
  end;
end;

function THallucScan.IsDeclaredHere(const Name: string): Boolean;
begin
  Result := FDeclared.ContainsKey(UpperCase(Name));
end;

function THallucScan.KnownInAnyUsedUnit(const Name: string): Boolean;
var
  U: string;
begin
  for U in FUnits do
    if LookupFPCSymbol(U, Name).Found then
      Exit(True);
  // System は uses に書かなくても常に見える（Length/SetLength 等の組み込みも
  // system.ppu にコンパイラ内部シンボルとして載っている）。ObjPas も
  // {$mode objfpc}/{$mode delphi} では暗黙に uses される
  // （AssignFile/CloseFile 等の Delphi 互換別名はここにいる）。
  Result := LookupFPCSymbol('system', Name).Found or
            LookupFPCSymbol('objpas', Name).Found;
end;

procedure THallucScan.CheckQualified(const Node: TSNode);
var
  LhsNode, RhsNode: TSNode;
  Qualifier, Name: string;
  U: string;
  Matched: string;
begin
  if not FindFieldChild(Node, 'lhs', LhsNode) then Exit;
  if not FindFieldChild(Node, 'rhs', RhsNode) then Exit;
  if ts_node_type(LhsNode) <> 'identifier' then Exit;
  if ts_node_type(RhsNode) <> 'identifier' then Exit;

  Qualifier := FCtx.GetNodeText(LhsNode);
  // 同名のローカル変数・型がファイル内で宣言されていたら、それはユニット参照
  // ではないかもしれないので触らない。
  if IsDeclaredHere(Qualifier) then Exit;

  Matched := '';
  for U in FUnits do
    if CompareText(U, Qualifier) = 0 then
    begin
      Matched := U;
      Break;
    end;
  if Matched = '' then Exit;
  if not IsStrictFPCUnit(Matched) then Exit;

  Name := FCtx.GetNodeText(RhsNode);
  if LookupFPCSymbol(Matched, Name).Found then Exit;

  FCtx.Report(CRuleId,
    Format('"%s" is not declared in FPC unit %s', [Name, Matched]), RhsNode);
end;

procedure THallucScan.CheckUnqualifiedCall(const Node: TSNode);
var
  EntityNode: TSNode;
  Name: string;
begin
  if not FUnqualifiedEnabled then Exit;
  if not FindFieldChild(Node, 'entity', EntityNode) then Exit;
  if ts_node_type(EntityNode) <> 'identifier' then Exit;

  Name := FCtx.GetNodeText(EntityNode);
  if IsDeclaredHere(Name) then Exit;
  if KnownInAnyUsedUnit(Name) then Exit;

  FCtx.Report(CRuleId,
    Format('call to "%s", which is neither declared in this file nor found in the FPC units it uses', [Name]),
    EntityNode);
end;

procedure THallucScan.Walk(const Node: TSNode);
var
  NodeType: PAnsiChar;
  ChildCount, I: LongWord;
  ChildField: PAnsiChar;
  Child: TSNode;
begin
  NodeType := ts_node_type(Node);

  // uses 節・モジュール名・実装ヘッダの宣言名（genericDot）・`inherited Foo` は
  // いずれも「今どのシンボルを参照しているか」を判定できる文脈ではない。
  if (NodeType = 'declUses') or (NodeType = 'moduleName') or
     (NodeType = 'genericDot') or (NodeType = 'inherited') then Exit;

  if NodeType = 'with' then
  begin
    // 本体の裸の名前は with に渡したレコード/オブジェクトのメンバでありうる。
    ChildCount := ts_node_child_count(Node);
    I := 0;
    while I < ChildCount do
    begin
      ChildField := ts_node_field_name_for_child(Node, I);
      if (ChildField <> nil) and (ChildField = 'entity') then
        Walk(ts_node_child(Node, I));
      Inc(I);
    end;
    Exit;
  end;

  if NodeType = 'exprDot' then
  begin
    CheckQualified(Node);
    // rhs は「何かのメンバ名」で、lhs の型が分からない限り判定できない
    // （判定Aで扱えるのは lhs がユニット名の場合だけ）。lhs 側は式なので辿る。
    if FindFieldChild(Node, 'lhs', Child) then
      Walk(Child);
    Exit;
  end;

  if NodeType = 'exprCall' then
    CheckUnqualifiedCall(Node);

  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    Child := ts_node_child(Node, I);
    ChildField := ts_node_field_name_for_child(Node, I);
    // exprCall の entity が単純な identifier の場合は CheckUnqualifiedCall で
    // 判定済みなので、裸の識別子として二重に辿らない。
    if (NodeType = 'exprCall') and (ChildField <> nil) and (ChildField = 'entity') and
       (ts_node_type(Child) = 'identifier') then
    begin
      Inc(I);
      Continue;
    end;
    Walk(Child);
    Inc(I);
  end;
end;

function TRuleHalluc001.RuleId: string;
begin
  Result := CRuleId;
end;

function TRuleHalluc001.Description: string;
begin
  Result := 'reference to an identifier that does not exist in the FPC RTL/FCL units in scope';
end;

function TRuleHalluc001.InterestedNodeTypes: TStringArray;
begin
  // RAWPACO-DEPR-001/002 と同じ理由で root のみ（ファイル単位の収集→照合を
  // 1回の Check の中で完結させ、使い回されるルールインスタンスに状態を
  // 持たせないため）。
  Result := TStringArray.Create('root');
end;

procedure TRuleHalluc001.Check(const Node: TSNode; Ctx: TLintContext);
var
  Scan: THallucScan;
  Units: TUnitList;
  Declared: TNameSet;
  U: string;
  AllUsesKnown: Boolean;
begin
  if not FPCSymbolsAvailable then Exit;
  // 構文エラーを含むファイルでは木の形自体が信用できない。
  if ts_node_has_error(Node) then Exit;

  Units := TUnitList.Create;
  Declared := TNameSet.Create;
  Scan := THallucScan.Create;
  try
    CollectUsedUnits(Node, Ctx, Units);
    AllUsesKnown := True;
    for U in Units do
      if not IsKnownFPCUnit(U) then
        AllUsesKnown := False;

    CollectDeclaredNames(Node, Ctx, Declared);

    Scan.FCtx := Ctx;
    Scan.FUnits := Units;
    Scan.FDeclared := Declared;
    // 判定Bは「uses が1つ以上あり、その全てが既知ユニットである」場合に限る。
    // uses が空のファイル（include 断片、`{$i}` で組み立てられる RTL の
    // 内部ユニット等）では、参照できる名前の出所を構文木から特定できないため
    // 有効にしてはいけない（実測でこれが誤検知の主要因の1つだった）。
    Scan.FUnqualifiedEnabled := AllUsesKnown and (Units.Count > 0) and
      IsCompilationUnit(Node) and
      not HasDisablingDirective(Ctx.GetNodeText(Node));
    Scan.Walk(Node);
  finally
    Scan.Free;
    Declared.Free;
    Units.Free;
  end;
end;

initialization
  RegisterRule(TRuleHalluc001.Create);

end.
