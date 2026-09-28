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
    function Severity: TSeverity;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

implementation

uses
  FPCSymbols, ASTHelpers;

const
  CRuleId = 'RAWPACO-DEPR-002';
  // 設計書4.1.2節: 検知対象のRTL/FCLシンボルは今も動作する非推奨API。
  // 今すぐ壊れているわけではない前向きな移行シグナルなので、既定では
  // CIを落とさないWarning階層。
  CSeverity = svWarning;

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
    FCtx.Report(CRuleId, CSeverity,
      Format('use of "%s", which is deprecated in FPC unit %s', [Name, AUnitName]), Node)
  else
    FCtx.Report(CRuleId, CSeverity,
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
  RhsNode: TSNode;
  QualifierUnit, Qualifier, FirstSegment, Name: string;
  Info: TFPCSymbolInfo;
begin
  if not FindFieldChild(Node, 'rhs', RhsNode) then Exit;
  if ts_node_type(RhsNode) <> 'identifier' then Exit;

  // lhs は単純な identifier だけでなく、`Generics.Collections` のような
  // ドット付きユニット名（lhs 自体が exprDot）も受け付ける
  // （ASTHelpers.TryGetDotQualifier のコメント参照）。
  if not TryGetDotQualifier(Node, FCtx, Qualifier, FirstSegment) then Exit;
  if FDeclared.ContainsKey(UpperCase(FirstSegment)) then Exit;

  QualifierUnit := FindUnitByName(FUnits, Qualifier);
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
  Child: TSNode;
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
    for Child in CollectFieldChildren(Node, 'entity') do
      Walk(Child, 'entity');
    Exit;
  end;

  if NodeType = 'exprDot' then
  begin
    CheckDotted(Node);
    // lhs 側はさらにネストした exprDot / exprCall でありうるので走査を続けるが、
    // rhs は「何かのメンバ名」であり型解決なしには意味を判定できないため見ない。
    for Child in CollectFieldChildren(Node, 'lhs') do
      Walk(Child, 'lhs');
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

function TRuleDepr002.Severity: TSeverity;
begin
  Result := CSeverity;
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

    CollectDeclaredNames(Node, Ctx, Declared); // 制約2（シャドウイング対策）用

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
