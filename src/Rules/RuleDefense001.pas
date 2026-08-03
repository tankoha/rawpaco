unit RuleDefense001;

{$mode objfpc}{$H+}

// RAWPACO-DEFENSE-001: 空のexceptハンドラ(例外の握りつぶし)検知。
// docs/RULE_ENGINE_DESIGN.md P1に対応。
//
// tree-sitter-pascal(v0.10.2)の実際のノード構造(vendor/tree-sitter-pascal/
// src/node-types.jsonとgrammar.jsで確認済み。設計書の当初案は未検証だった
// exceptionHandler/exceptionElseをexcept節全体を表すノードであるかのように
// 書いていたが、実際は以下の通り):
//
// - try/except/finally全体は単一ノード種別`try`。exceptフィールドは
//   multiple:trueで、`kExcept`トークン自身と、後続の`statements`/
//   `exceptionHandler`/`exceptionElse`が同じフィールド名`except`で
//   複数の子として並ぶ。
// - `try ... except end;`(完全に空)は、exceptフィールドの子が`kExcept`
//   トークンのみになる。
// - `try ... except ; end;`は、exceptフィールドの2番目の子が`statements`
//   ノードで、その named_child_count が0になる(`;`は無名トークンなので
//   named版でのみ0になる。child_countは1のまま)。
// - `exceptionHandler`(`on E: Exception do ...`)はbodyフィールドを持ち、
//   本体が`;`単体の場合 ts_node_type(body) = ';' になる。

interface

uses
  SysUtils, TSBindings, Diagnostics, RuleRegistry;

type
  TRuleDefense001 = class(TInterfacedObject, IRawpacoRule)
  public
    function RuleId: string;
    function Description: string;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  private
    procedure CheckTry(const Node: TSNode; Ctx: TLintContext);
    procedure CheckExceptionHandler(const Node: TSNode; Ctx: TLintContext);
  end;

implementation

const
  CRuleId = 'RAWPACO-DEFENSE-001';

function TRuleDefense001.RuleId: string;
begin
  Result := CRuleId;
end;

function TRuleDefense001.Description: string;
begin
  Result := 'empty except handler (exception silently swallowed)';
end;

function TRuleDefense001.InterestedNodeTypes: TStringArray;
begin
  Result := TStringArray.Create('try', 'exceptionHandler');
  // exceptionElse(on節リストの`else`分岐)は対象外とする。node-types.json
  // 上、専用のbodyフィールドを持たず`kElse`+文の子ノードが並ぶだけの構造
  // であり、空判定には別ロジックが必要になるため、今回のスコープからは
  // 意図的に外す(CLAUDE.mdルール8: スコープを絞った理由を明記)。
end;

procedure TRuleDefense001.Check(const Node: TSNode; Ctx: TLintContext);
var
  NodeType: PAnsiChar;
begin
  NodeType := ts_node_type(Node);
  if NodeType = 'try' then
    CheckTry(Node, Ctx)
  else if NodeType = 'exceptionHandler' then
    CheckExceptionHandler(Node, Ctx);
end;

procedure TRuleDefense001.CheckTry(const Node: TSNode; Ctx: TLintContext);
var
  ChildCount, I: LongWord;
  ExceptChildren: array of TSNode;
begin
  SetLength(ExceptChildren, 0);
  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do // 符号なしLongWordのため"for I := 0 to Count-1"は
                          // Count=0でアンダーフローする(ASTWalker.pas参照)。
  begin
    if ts_node_field_name_for_child(Node, I) = 'except' then
    begin
      SetLength(ExceptChildren, Length(ExceptChildren) + 1);
      ExceptChildren[High(ExceptChildren)] := ts_node_child(Node, I);
    end;
    Inc(I);
  end;

  if Length(ExceptChildren) = 0 then
    Exit; // except節自体がない(try/finallyのみ) — このルールの対象外

  if Length(ExceptChildren) = 1 then
  begin
    // `except`フィールドの子が`kExcept`トークン自身しかない = exceptと
    // endの間に何もない。位置はexceptキーワード自体(ExceptChildren[0])
    // を指す方が、try本体が長い場合でも問題箇所を正確に示せる。
    Ctx.Report(CRuleId,
      'except block is empty: the exception is caught and silently discarded',
      ExceptChildren[0]);
    Exit;
  end;

  // except節に2件以上ある場合、kExceptに続く`statements`ノードが
  // named_child_count=0であれば`except ; end`パターンとして報告する。
  // exceptionHandler/exceptionElse型の子はCheckExceptionHandler側で
  // 個別に見るため、ここではスキップする(二重報告防止)。
  for I := 1 to High(ExceptChildren) do
    if (ts_node_type(ExceptChildren[I]) = 'statements') and
       (ts_node_named_child_count(ExceptChildren[I]) = 0) then
      Ctx.Report(CRuleId,
        'except block contains no statements (only ";"): the exception is silently discarded',
        ExceptChildren[I]);
end;

procedure TRuleDefense001.CheckExceptionHandler(const Node: TSNode; Ctx: TLintContext);
var
  ChildCount, I: LongWord;
  BodyNode: TSNode;
  Found: Boolean;
begin
  Found := False;
  BodyNode := Node; // ダミー初期値。Found=Falseなら以降参照しない。
  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    if ts_node_field_name_for_child(Node, I) = 'body' then
    begin
      BodyNode := ts_node_child(Node, I);
      Found := True;
      Break;
    end;
    Inc(I);
  end;

  if not Found then
    Exit; // 文法上bodyは必ず存在するはずだが、将来の文法変更やエラー
          // ノードに備え、見つからない場合は何もしない(CLAUDE.mdルール5)。

  if ts_node_type(BodyNode) = ';' then
    // 報告位置はハンドラノード自体(`on ... do`節)。裸の`;`トークンを
    // 直接指すより、人間が読める文脈を示せる。
    Ctx.Report(CRuleId,
      'exception handler ("on ... do") has an empty body (";"): the exception is silently discarded',
      Node);
end;

initialization
  RegisterRule(TRuleDefense001.Create);

end.
