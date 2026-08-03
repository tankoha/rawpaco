unit RuleSec001;

{$mode objfpc}{$H+}

// RAWPACO-SEC-001: SQL文字列の連結構築(SQLインジェクションの疑い)検知。
// docs/RULE_ENGINE_DESIGN.md P2/2.4節1に対応。
//
// tree-sitter-pascal(v0.10.2)の実際のノード構造(vendor/tree-sitter-pascal/
// src/node-types.json・grammar.jsで確認済み):
//
// - 二項式は単一ノード種別`exprBinary`、フィールドはlhs/operator/rhs。
// - `+`演算子はoperatorフィールドの子として現れる`kAdd`という"名前付き"
//   ノード(grammar.js: kAdd: $ => '+')であり、'+'という無名トークン自体
//   ではない。
// - 文字列リテラルは`literalString`。ts_node_start_byte/end_byteで
//   切り出したテキストは前後の引用符を含む(TLintContext.GetNodeText参照)。
//
// 誤検知回避方針(CLAUDE.mdルール5):
// - 両辺ともliteralStringの場合(完全に静的な文字列)は対象外とする。
//   外部入力が混入する余地がないため。
// - 両辺ともliteralStringでない場合(SQLキーワードを含むリテラルが
//   そもそも存在しない)も対象外。
// - 「片方だけがliteralStringで、かつSQLキーワードを含む」場合のみ報告。
// - キーワード一致は単語境界を要求する(例: "WHEREABOUTS"のような偶然の
//   部分一致を除外するため)。GetNodeTextは引用符込みのテキストを返すため、
//   引用符自体が非単語文字として自然に境界の役割を果たす。

interface

uses
  SysUtils, StrUtils, TSBindings, Diagnostics, RuleRegistry;

type
  TRuleSec001 = class(TInterfacedObject, IRawpacoRule)
  public
    function RuleId: string;
    function Description: string;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

implementation

const
  CRuleId = 'RAWPACO-SEC-001';

  // 一般的すぎる語(UPDATE等は英単語としても使われる)を承知の上で、
  // Bandit(Python)のB608等、他言語の静的解析ツールでも実績のある
  // ヒューリスティックとして採用する(docs/RULE_ENGINE_DESIGN.md 2.4節)。
  CSqlKeywords: array[0..5] of string = (
    'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'WHERE', 'FROM'
  );

function IsWordChar(C: AnsiChar): Boolean; inline;
begin
  Result := C in ['A'..'Z', '0'..'9', '_'];
end;

// LiteralTextはGetNodeTextで切り出した引用符込みの生トークン文字列。
// キーワードが単語境界(非単語文字、または文字列の端)に囲まれている
// 場合のみ真とする("WHEREABOUTS"のような偶然の部分一致を除外)。
function ContainsSqlKeyword(const LiteralText: AnsiString): Boolean;
var
  Upper: AnsiString;
  KW: string;
  P, KWLen, TextLen: SizeInt;
begin
  Result := False;
  Upper := UpperCase(LiteralText);
  TextLen := Length(Upper);
  for KW in CSqlKeywords do
  begin
    KWLen := Length(KW);
    P := PosEx(KW, Upper, 1);
    while P > 0 do
    begin
      if ((P = 1) or (not IsWordChar(Upper[P - 1]))) and
         ((P + KWLen > TextLen) or (not IsWordChar(Upper[P + KWLen]))) then
        Exit(True);
      P := PosEx(KW, Upper, P + 1);
    end;
  end;
end;

function TRuleSec001.RuleId: string;
begin
  Result := CRuleId;
end;

function TRuleSec001.Description: string;
begin
  Result := 'SQL built via string concatenation with a SQL-keyword literal and non-literal input (possible SQL injection)';
end;

function TRuleSec001.InterestedNodeTypes: TStringArray;
begin
  Result := TStringArray.Create('exprBinary');
end;

procedure TRuleSec001.Check(const Node: TSNode; Ctx: TLintContext);
var
  ChildCount, I: LongWord;
  OperatorNode, LhsNode, RhsNode: TSNode;
  HasOperator, HasLhs, HasRhs, LhsIsLiteral, RhsIsLiteral: Boolean;
const
  CMessage = 'string concatenation builds SQL from a literal containing a SQL keyword and non-literal input; use parameterized queries instead';
begin
  HasOperator := False;
  HasLhs := False;
  HasRhs := False;
  OperatorNode := Node; // ダミー初期値(未使用のまま参照されないことを保証)。
  LhsNode := Node;
  RhsNode := Node;

  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do // LongWordなので"0 to Count-1"は使わない(ASTWalker参照)
  begin
    if ts_node_field_name_for_child(Node, I) = 'operator' then
    begin
      OperatorNode := ts_node_child(Node, I);
      HasOperator := True;
    end
    else if ts_node_field_name_for_child(Node, I) = 'lhs' then
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

  if not (HasOperator and HasLhs and HasRhs) then
    Exit; // 文法上は3つとも必須のはずだが、将来の文法変更に備え防御的に(rule 5)

  if ts_node_type(OperatorNode) <> 'kAdd' then
    Exit; // +以外の二項演算子(比較・算術等)は対象外

  LhsIsLiteral := ts_node_type(LhsNode) = 'literalString';
  RhsIsLiteral := ts_node_type(RhsNode) = 'literalString';

  if LhsIsLiteral = RhsIsLiteral then
    Exit; // 両方リテラル(完全に静的)/両方非リテラル(SQLキーワードの入りようがない)は対象外

  if LhsIsLiteral then
  begin
    if ContainsSqlKeyword(Ctx.GetNodeText(LhsNode)) then
      Ctx.Report(CRuleId, CMessage, Node);
  end
  else
  begin
    if ContainsSqlKeyword(Ctx.GetNodeText(RhsNode)) then
      Ctx.Report(CRuleId, CMessage, Node);
  end;
end;

initialization
  RegisterRule(TRuleSec001.Create);

end.
