unit RuleSec002;

{$mode objfpc}{$H+}

// RAWPACO-SEC-002: シークレットらしき文字列のハードコード検知。
// docs/RULE_ENGINE_DESIGN.md P3/2.4節2に対応。
//
// 対象ノード種別(node-types.json/grammar.jsで確認済み):
// - `assignment`(フィールド: lhs/operator/rhs)の単純な
//   `identifier := literalString`の形のみを対象とする。
//   lhsがvarAssignDef(FPCのinline `for var I := ...`)や、exprDot
//   (`Obj.Password := 'x'`のようなプロパティ・フィールドへの代入。実務上
//   はこちらの方がむしろ典型的なシークレットハードコードパターンだが)
//   である場合は、このルールの最初の実装では意図的にスコープ外とする
//   (CLAUDE.mdルール8)。理由: exprDotのrhs側から末端の識別子名を
//   取り出すロジックが別途必要になり、単純な代入検知という第一段の
//   スコープを超えるため。将来の拡張候補としてHANDOFF.mdに明記する。
//   rhsがliteralString以外(exprBinaryでの連結、関数呼び出しの戻り値等)
//   も同様に対象外(値の実体追跡は意味解析でありスコープ外)。
// - `declVar`/`declConst`のdefaultValue付き宣言。
//   - declVarのnameフィールドはmultiple:trueで、複数識別子
//     (`var A, B: T`)の場合は識別子と`,`トークンが同じフィールド名で
//     並ぶ(node-types.json)。最初に見つかったidentifier型の子だけを
//     見る単純化を採用する。理由: FPCの初期化付きvar宣言
//     (`var X: T = V;`)は仕様上、複数識別子への単一初期値付与を許さない
//     ため、複数名+初期値という入力自体が現実的なPascalコードとして
//     発生しない(グラマー上パースは通っても意味的には無効)。
//   - `defaultValue`ノード自身はfields={}(node-types.jsonで確認済み)で、
//     `kEq`トークンと初期値式が位置的に並ぶだけでフィールド名を持たない。
//     そのため、フィールド名検索ではなく「kEq以外の子」を初期値として
//     拾う(この文法特有の回避策)。
// - 手続き・関数の引数宣言(`var Foo: T`)はdeclArgという別のノード種別に
//   なる(node-types.jsonで確認済み)。このルールがInterestedNodeTypesに
//   declArgを含めていないため、引数リストの`var`宣言には自然に反応しない
//   (declVarとの取り違えではなく文法上別ノードだから、というのが理由)。
//
// 誤検知回避方針(CLAUDE.mdルール5):
// - 識別子名の判定は単純な部分一致ではなく「接尾辞一致」とする
//   (NameEndsWithSecretKeyword参照)。単純部分一致だと`TokenList`/
//   `TokenCount`/`SecretSanta`のような無関係な識別子まで誤検知するため
//   (設計検証で発見)。PascalCase慣習では役割語が識別子の末尾に来ることを
//   利用する。トレードオフとして`MyOwnSecretKey`のような複合名は取りこぼす
//   可能性があるが、意図的に安全側(false negative)に倒した結果。
// - 値のプレースホルダ判定は部分一致とする。実務での表記揺れ
//   (YOUR_API_KEY_HERE等)が大きいため、完全一致より緩めに倒す。

interface

uses
  SysUtils, TSBindings, Diagnostics, RuleRegistry;

type
  TRuleSec002 = class(TInterfacedObject, IRawpacoRule)
  public
    function RuleId: string;
    function Description: string;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  private
    procedure CheckAssignment(const Node: TSNode; Ctx: TLintContext);
    procedure CheckDecl(const Node: TSNode; Ctx: TLintContext);
    procedure CheckNameAndValue(const NameText: string; const ValueNode: TSNode; Ctx: TLintContext);
  end;

implementation

const
  CRuleId = 'RAWPACO-SEC-002';

  // 識別子名の"末尾語"としてこれらに一致する場合のみシークレットらしいと
  // 判定する(単純な部分一致ではなく接尾辞一致)。
  CSecretNameKeywords: array[0..7] of string = (
    'PASSWORD', 'SECRET', 'SECRETKEY', 'APIKEY', 'API_KEY', 'TOKEN',
    'CONNECTIONSTRING', 'PRIVATEKEY'
  );

  // プレースホルダらしき値のマーカー。完全一致ではなく部分一致(contains)
  // で判定し、誤って本物のシークレットを見逃す(false negative)方向に
  // 倒す(CLAUDE.mdルール5)。
  CPlaceholderMarkers: array[0..9] of string = (
    'CHANGEME', 'CHANGE_ME', 'YOUR_', 'PLACEHOLDER', 'TODO', 'FIXME',
    'XXX', 'REDACTED', 'DUMMY', 'EXAMPLE'
  );

// 識別子名が「PasswordList」「TokenCount」「SecretSanta」のような、
// シークレットとは無関係な語を先頭側の構成要素として含むだけのケースを
// 誤検知しないよう、単純な部分一致ではなく「末尾の語として一致するか」を
// 見る。実務でのシークレット系識別子(AuthToken/DbPassword/ApiKey/
// DbConnectionString等)は、役割を表す語がほぼ常に識別子の末尾に来る
// PascalCase慣習に従うため、この判定で実用上の取りこぼしは少ないと判断
// した。
function NameEndsWithSecretKeyword(const Name: string): Boolean;
var
  Upper, Stripped: string;
  KW: string;
begin
  Result := False;
  Upper := UpperCase(Name);
  Stripped := Upper;
  // 末尾の数字・アンダースコアは"AuthToken2"のようなバージョン付き識別子でも
  // 意味のある末尾語(この場合Token)を正しく判定するために取り除く。
  while (Length(Stripped) > 0) and (Stripped[Length(Stripped)] in ['0'..'9', '_']) do
    Delete(Stripped, Length(Stripped), 1);
  for KW in CSecretNameKeywords do
    if (Length(Stripped) >= Length(KW)) and
       (Copy(Stripped, Length(Stripped) - Length(KW) + 1, Length(KW)) = KW) then
      Exit(True);
end;

function ValueLooksLikePlaceholder(const Value: string): Boolean;
var
  Upper, Marker: string;
begin
  Upper := UpperCase(Value);
  for Marker in CPlaceholderMarkers do
    if Pos(Marker, Upper) > 0 then
      Exit(True);
  Result := False;
end;

function TRuleSec002.RuleId: string;
begin
  Result := CRuleId;
end;

function TRuleSec002.Description: string;
begin
  Result := 'hardcoded secret-like string literal assigned to a password/secret/token/apikey/connection-string-named identifier';
end;

function TRuleSec002.InterestedNodeTypes: TStringArray;
begin
  Result := TStringArray.Create('assignment', 'declVar', 'declConst');
end;

procedure TRuleSec002.Check(const Node: TSNode; Ctx: TLintContext);
var
  NodeType: PAnsiChar;
begin
  NodeType := ts_node_type(Node);
  if NodeType = 'assignment' then
    CheckAssignment(Node, Ctx)
  else if (NodeType = 'declVar') or (NodeType = 'declConst') then
    CheckDecl(Node, Ctx);
end;

procedure TRuleSec002.CheckAssignment(const Node: TSNode; Ctx: TLintContext);
var
  ChildCount, I: LongWord;
  LhsNode, RhsNode: TSNode;
  HasLhs, HasRhs: Boolean;
begin
  HasLhs := False;
  HasRhs := False;
  LhsNode := Node; // ダミー初期値
  RhsNode := Node;

  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    if ts_node_field_name_for_child(Node, I) = 'lhs' then
    begin
      LhsNode := ts_node_child(Node, I);
      HasLhs := True;
    end
    else if ts_node_field_name_for_child(Node, I) = 'rhs' then
    begin
      RhsNode := ts_node_child(Node, I);
      HasRhs := True;
    end;
    Inc(I);
  end;

  if not (HasLhs and HasRhs) then
    Exit;

  // スコープ限定: 単一識別子への直接代入のみ(varAssignDef/exprDotは対象外。
  // ユニット冒頭コメント参照)。
  if ts_node_type(LhsNode) <> 'identifier' then
    Exit;

  // スコープ限定: rhsが直接literalStringである場合のみ(連結・関数呼び出し
  // 経由の値は対象外)。
  if ts_node_type(RhsNode) <> 'literalString' then
    Exit;

  CheckNameAndValue(Ctx.GetNodeText(LhsNode), RhsNode, Ctx);
end;

procedure TRuleSec002.CheckDecl(const Node: TSNode; Ctx: TLintContext);
var
  ChildCount, I, DVChildCount, J: LongWord;
  NameNode, DefaultValueNode, ValueNode: TSNode;
  HasName, HasDefaultValue, FoundValue: Boolean;
begin
  HasName := False;
  HasDefaultValue := False;
  NameNode := Node; // ダミー初期値
  DefaultValueNode := Node;

  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    // nameフィールドは複数識別子の場合","トークンも同じフィールド名で
    // 並ぶ(node-types.json)。最初に見つかったidentifier型だけを見る
    // 簡略化(ユニット冒頭コメント参照)。
    if (not HasName) and (ts_node_field_name_for_child(Node, I) = 'name') and
       (ts_node_type(ts_node_child(Node, I)) = 'identifier') then
    begin
      NameNode := ts_node_child(Node, I);
      HasName := True;
    end
    else if ts_node_field_name_for_child(Node, I) = 'defaultValue' then
    begin
      DefaultValueNode := ts_node_child(Node, I);
      HasDefaultValue := True;
    end;
    Inc(I);
  end;

  if not (HasName and HasDefaultValue) then
    Exit; // 初期値なしのvar宣言は対象外

  // defaultValueはfields={}なので、kEq以外の子を初期値として拾う
  // (ユニット冒頭コメント参照)。
  ValueNode := DefaultValueNode; // ダミー初期値
  FoundValue := False;
  DVChildCount := ts_node_child_count(DefaultValueNode);
  J := 0;
  while J < DVChildCount do
  begin
    if ts_node_type(ts_node_child(DefaultValueNode, J)) <> 'kEq' then
    begin
      ValueNode := ts_node_child(DefaultValueNode, J);
      FoundValue := True;
      Break;
    end;
    Inc(J);
  end;

  if not FoundValue then
    Exit;

  if ts_node_type(ValueNode) <> 'literalString' then
    Exit;

  CheckNameAndValue(Ctx.GetNodeText(NameNode), ValueNode, Ctx);
end;

procedure TRuleSec002.CheckNameAndValue(const NameText: string; const ValueNode: TSNode; Ctx: TLintContext);
var
  RawValueText, Unquoted, Trimmed: AnsiString;
begin
  if not NameEndsWithSecretKeyword(NameText) then
    Exit;

  RawValueText := Ctx.GetNodeText(ValueNode);
  // literalStringのバイト範囲は引用符込み(検証済み事実)。空文字列リテラル
  // でも''の2バイトはあるはずだが、万一の文法変化に備え防御的にチェック。
  if Length(RawValueText) < 2 then
    Exit;
  Unquoted := Copy(RawValueText, 2, Length(RawValueText) - 2);
  Trimmed := Trim(Unquoted);
  if Trimmed = '' then
    Exit;
  if ValueLooksLikePlaceholder(Trimmed) then
    Exit;

  Ctx.Report(CRuleId,
    Format('possible hardcoded secret: "%s" is assigned a literal string value', [NameText]),
    ValueNode);
end;

initialization
  RegisterRule(TRuleSec002.Create);

end.
