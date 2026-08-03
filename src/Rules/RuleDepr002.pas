unit RuleDepr002;

{$mode objfpc}{$H+}

// RAWPACO-DEPR-002: FPC の RTL/FCL が `deprecated` を付けているシンボルの使用を検知。
// docs/RULE_ENGINE_DESIGN.md P6/2.5節に対応。
//
// データ源は data/fpc-rtl-symbols.txt（生成手順は tools/gen_fpc_symbols.sh、
// 読み込みは src/FPCSymbols.pas）。FPC 3.2.2 の .ppu から抽出した「ユニット
// レベルで公開されている deprecated シンボル」29件が対象。実際に含まれるのは
// SysUtils の DecimalSeparator / ShortDateFormat / DateSeparator 等の
// グローバル変数群（現在は DefaultFormatSettings のフィールドを使うのが正）と
// SysUtils.GetTickCount（GetTickCount64 が正）などで、いずれも古い書き方として
// 実際に生成コードに現れやすいものである。
//
// 誤検知を避けるための制約（CLAUDE.mdルール5。全て意図的に「狭く」してある）:
//
//   1. 対象ファイルが実際に uses しているユニット（および常に暗黙で使える
//      System）の deprecated シンボルしか見ない。
//   2. 同じ名前がそのファイル自身のどこかで宣言されている場合、その名前は
//      判定対象から丸ごと外す。スコープ解決はできないので、ローカル変数や
//      自前の手続きが RTL の名前を隠しているケースを区別できないため
//      （例: 自前で `DecimalSeparator: Char` を宣言しているファイル）。
//   3. `Foo.Bar` 形式（exprDot）は、lhs がそのファイルの uses に現れる
//      ユニット名である場合にだけ rhs を見る。`FormatSettings.DecimalSeparator`
//      のようなレコードフィールドへのアクセスは（むしろ推奨される書き方なので）
//      決して検知してはならない。lhs がユニット名でない exprDot は rhs 側の
//      走査自体を打ち切る。
//   4. 宣言側の識別子（親ノードのフィールド名が `name` である identifier）と
//      `moduleName`（unit/program 名、uses のユニット名）は見ない。
//
// tree-sitter-pascal(v0.10.2) の実際の文法（プローブプログラムで実機確認済み）:
//   - uses 節は `declUses` で、各ユニットは `moduleName` ノード（その下に
//     `identifier`)。interface 部・implementation 部の両方に現れうる。
//   - `A.B` は `exprDot`（フィールド lhs / operator / rhs）。`A.B.C` は
//     lhs 側がネストした `exprDot` になる。
//   - 宣言名は declVar / declConst / declType / declProc / declField /
//     declArg / declProp / declEnumValue / declLabel いずれもフィールド名 `name`。
//     `declVar`/`declField` は `A, B: Integer;` のように `name` を複数持ちうる。
//   - `procedure TFoo.Bar;` の実装ヘッダの名前は `genericDot`（exprDot ではない）。

interface

uses
  SysUtils, Generics.Collections, TSBindings, Diagnostics, RuleRegistry;

type
  TRuleDepr002 = class(TInterfacedObject, IRawpacoRule)
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
  CRuleId = 'RAWPACO-DEPR-002';

type
  TNameSet = specialize TDictionary<string, Boolean>;
  TUnitList = specialize TList<string>;

// ファイル内の全ての宣言名（大文字化）を集める。制約2のシャドウイング対策。
procedure CollectDeclaredNames(const Node: TSNode; Ctx: TLintContext; Names: TNameSet);
var
  ChildCount, I, NamedCount, J: LongWord;
  Child: TSNode;
  FieldName: PAnsiChar;
  Key: string;
begin
  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    FieldName := ts_node_field_name_for_child(Node, I);
    if (FieldName <> nil) and (FieldName = 'name') then
    begin
      Child := ts_node_child(Node, I);
      if ts_node_type(Child) = 'identifier' then
      begin
        Key := UpperCase(Ctx.GetNodeText(Child));
        Names.AddOrSetValue(Key, True);
      end;
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

// uses 節に現れるユニット名を集める（元の綴りのまま。メッセージに使う）。
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

function FindUnitByName(Units: TUnitList; const Name: string): string;
var
  U: string;
begin
  Result := '';
  for U in Units do
    if CompareText(U, Name) = 0 then
      Exit(U);
end;

type
  TDepr002Scan = class
  private
    FCtx: TLintContext;
    FUnits: TUnitList;      // uses に現れた「既知の」ユニット名
    FDeclared: TNameSet;
    procedure ReportSymbol(const Node: TSNode; const AUnitName, Name: string;
      const Hint: string);
    // 名前が「uses しているいずれかの既知ユニット + System」で deprecated かを引く。
    function FindDeprecated(const Name: string; out AUnitName, Hint: string): Boolean;
    procedure CheckDotted(const Node: TSNode);
  public
    procedure Walk(const Node: TSNode; const FieldName: string);
  end;

procedure TDepr002Scan.ReportSymbol(const Node: TSNode; const AUnitName, Name: string;
  const Hint: string);
begin
  if Hint = '' then
    FCtx.Report(CRuleId,
      Format('use of "%s", which is deprecated in FPC unit %s', [Name, AUnitName]), Node)
  else
    FCtx.Report(CRuleId,
      Format('use of "%s", which is deprecated in FPC unit %s (%s)', [Name, AUnitName, Hint]), Node);
end;

function TDepr002Scan.FindDeprecated(const Name: string; out AUnitName, Hint: string): Boolean;
var
  U: string;
  Info: TFPCSymbolInfo;
begin
  Result := False;
  AUnitName := '';
  Hint := '';
  if FDeclared.ContainsKey(UpperCase(Name)) then Exit;

  for U in FUnits do
  begin
    Info := LookupFPCSymbol(U, Name);
    if Info.Found and Info.Exported and Info.IsDeprecated then
    begin
      AUnitName := U;
      Hint := Info.DeprecationHint;
      Exit(True);
    end;
  end;

  // System は uses に書かなくても常に見える。
  Info := LookupFPCSymbol('system', Name);
  if Info.Found and Info.Exported and Info.IsDeprecated then
  begin
    AUnitName := 'System';
    Hint := Info.DeprecationHint;
    Exit(True);
  end;
end;

procedure TDepr002Scan.CheckDotted(const Node: TSNode);
var
  ChildCount, I: LongWord;
  FieldName: PAnsiChar;
  LhsNode, RhsNode: TSNode;
  HasLhs, HasRhs: Boolean;
  QualifierUnit, Name: string;
  Info: TFPCSymbolInfo;
begin
  HasLhs := False;
  HasRhs := False;
  LhsNode := Node;
  RhsNode := Node;
  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    FieldName := ts_node_field_name_for_child(Node, I);
    if FieldName <> nil then
    begin
      if FieldName = 'lhs' then begin LhsNode := ts_node_child(Node, I); HasLhs := True; end
      else if FieldName = 'rhs' then begin RhsNode := ts_node_child(Node, I); HasRhs := True; end;
    end;
    Inc(I);
  end;

  if not (HasLhs and HasRhs) then Exit;
  if ts_node_type(LhsNode) <> 'identifier' then Exit;
  if ts_node_type(RhsNode) <> 'identifier' then Exit;

  QualifierUnit := FindUnitByName(FUnits, FCtx.GetNodeText(LhsNode));
  if QualifierUnit = '' then Exit;

  Name := FCtx.GetNodeText(RhsNode);
  if FDeclared.ContainsKey(UpperCase(Name)) then Exit;

  Info := LookupFPCSymbol(QualifierUnit, Name);
  if Info.Found and Info.Exported and Info.IsDeprecated then
    ReportSymbol(RhsNode, QualifierUnit, Name, Info.DeprecationHint);
end;

procedure TDepr002Scan.Walk(const Node: TSNode; const FieldName: string);
var
  NodeType: PAnsiChar;
  ChildCount, I: LongWord;
  ChildField: PAnsiChar;
  Name, AUnitName, Hint: string;
begin
  NodeType := ts_node_type(Node);

  // uses 節・モジュール名は識別子ではなくユニット名なので判定対象外。
  // `genericDot` は `procedure TFoo.Bar;` のような実装ヘッダの宣言名であり
  // 使用箇所ではない（exprDot とは別ノード種別なので明示的に除外する）。
  if (NodeType = 'declUses') or (NodeType = 'moduleName') or
     (NodeType = 'genericDot') then Exit;

  // `with Rec do ... end` の中では、裸の識別子が Rec のフィールドを指しうる。
  // 型解決ができない以上「その名前がレコードのフィールドなのか RTL の
  // グローバルなのか」を区別できないため、body 側は丸ごと見ない。
  // これは実測に基づく対処である: FPCのソースツリー全体(4894ファイル)に
  // 当てたところ、`with FormatSettings do begin DecimalSeparator := '.'; ... end`
  // という典型的（かつ推奨される）書き方が誤検知として大量に出た。
  // entity 側（with に渡す式そのもの）は通常の式なので走査を続ける。
  if NodeType = 'with' then
  begin
    ChildCount := ts_node_child_count(Node);
    I := 0;
    while I < ChildCount do
    begin
      ChildField := ts_node_field_name_for_child(Node, I);
      if (ChildField <> nil) and (ChildField = 'entity') then
        Walk(ts_node_child(Node, I), 'entity');
      Inc(I);
    end;
    Exit;
  end;

  if NodeType = 'exprDot' then
  begin
    CheckDotted(Node);
    // lhs 側はさらにネストした exprDot / exprCall でありうるので走査を続けるが、
    // rhs は「何かのメンバ名」であり型解決なしには意味を判定できないため見ない。
    ChildCount := ts_node_child_count(Node);
    I := 0;
    while I < ChildCount do
    begin
      ChildField := ts_node_field_name_for_child(Node, I);
      if (ChildField <> nil) and (ChildField = 'lhs') then
        Walk(ts_node_child(Node, I), 'lhs');
      Inc(I);
    end;
    Exit;
  end;

  if NodeType = 'identifier' then
  begin
    // 宣言側の名前（declVar の name 等）は使用箇所ではない。
    if FieldName <> 'name' then
    begin
      Name := FCtx.GetNodeText(Node);
      if FindDeprecated(Name, AUnitName, Hint) then
        ReportSymbol(Node, AUnitName, Name, Hint);
    end;
    Exit;
  end;

  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    ChildField := ts_node_field_name_for_child(Node, I);
    if ChildField = nil then
      Walk(ts_node_child(Node, I), '')
    else
      Walk(ts_node_child(Node, I), ChildField);
    Inc(I);
  end;
end;

function TRuleDepr002.RuleId: string;
begin
  Result := CRuleId;
end;

function TRuleDepr002.Description: string;
begin
  Result := 'use of an FPC RTL/FCL symbol that is marked deprecated';
end;

function TRuleDepr002.InterestedNodeTypes: TStringArray;
begin
  // RAWPACO-DEPR-001 と同じ理由で root のみ（ファイル単位の収集→照合を
  // 1回の Check の中でローカル変数だけで完結させ、使い回されるルール
  // インスタンスに状態を持たせないため）。
  Result := TStringArray.Create('root');
end;

procedure TRuleDepr002.Check(const Node: TSNode; Ctx: TLintContext);
var
  Scan: TDepr002Scan;
  AllUnits, KnownUnits: TUnitList;
  Declared: TNameSet;
  U: string;
begin
  if not FPCSymbolsAvailable then Exit;

  AllUnits := TUnitList.Create;
  KnownUnits := TUnitList.Create;
  Declared := TNameSet.Create;
  Scan := TDepr002Scan.Create;
  try
    CollectUsedUnits(Node, Ctx, AllUnits);
    for U in AllUnits do
      if IsKnownFPCUnit(U) then
        KnownUnits.Add(U);
    // 既知ユニットが1つも無くても走査はする。System は uses に書かなくても
    // 常に見えるため（FindDeprecated が System を暗黙に見る）。

    CollectDeclaredNames(Node, Ctx, Declared);

    Scan.FCtx := Ctx;
    Scan.FUnits := KnownUnits;
    Scan.FDeclared := Declared;
    Scan.Walk(Node, '');
  finally
    Scan.Free;
    Declared.Free;
    KnownUnits.Free;
    AllUnits.Free;
  end;
end;

initialization
  RegisterRule(TRuleDepr002.Create);

end.
