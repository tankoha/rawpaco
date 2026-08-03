unit RuleDepr001;

{$mode objfpc}{$H+}

// RAWPACO-DEPR-001: 自己矛盾する非推奨API使用(同一ファイル内)検知。
// docs/RULE_ENGINE_DESIGN.md P4/2.5節に対応。対象コード自身が`deprecated`
// を付けて宣言した手続き・関数を、同一ファイル内で呼び出し続けているケース
// を検知する。外部データ(RTLシンボル一覧等)不要で構文木だけで完結する。
//
// tree-sitter-pascal(v0.10.2)の実際の文法(vendor/tree-sitter-pascal/
// src/node-types.json・grammar.jsで確認済み。実際にプローブプログラムを
// ビルドして生きた検証も行った):
//
// - 手続き・関数宣言は`declProc`(procedure/function/constructor/destructor
//   すべて共通)。フィールド`name`(単純な名前なら`identifier`)、
//   `attribute`(multiple:true。`deprecated`等の属性ごとに`procAttribute`
//   ノードが1つ)。
// - `procAttribute`ノードは専用のフィールドを持たず、`kDeprecated`を含む
//   様々な属性トークンが生の子ノードとして並ぶ(`deprecated;`単体でも
//   `deprecated '理由';`のようにメッセージ付きでも、子の1つが`kDeprecated`
//   型になる点は同じ)。
// - 呼び出し箇所の形は2種類ある:
//   1. 括弧付き呼び出し `Foo();`/`Foo(引数)`: `exprCall`ノード
//      (フィールド`entity`が呼び出し対象、単純な名前なら`identifier`)。
//   2. 括弧なし呼び出し `Foo;`(引数なし手続きのPascalらしい書き方):
//      `statement`ノードが唯一の子として`identifier`を直接持つ形になり、
//      `exprCall`は生成されない。Pascalの文法上、裸の識別子だけの文は
//      手続き・関数呼び出き以外の意味を持たないため、これも呼び出しとして
//      安全に扱える。
//   （`X := Foo;`のように代入式の右辺で関数呼び出しを行うケースは
//     `exprCall`にならず`assignment`の`rhs`が直接`identifier`になるが、
//     このルールでは意図的にスコープ外とする。理由: 括弧なし呼び出しの
//     判定に比べ「代入右辺の裸識別子」は本当に呼び出しなのか単なる変数
//     参照なのかの曖昧さが増し、対象を広げるほど誤検知のリスクが上がる
//     ため。CLAUDE.mdルール5(誤検知回避優先)に従い、確実に呼び出しと
//     判定できる2パターンのみに絞る）。
// - クラスメソッド経由の呼び出し(`Obj.Foo`/`Self.Foo`/`inherited Foo`等、
//   `exprDot`を伴う形)は対象外とする。`entity`フィールドが`exprDot`型に
//   なり単純な`identifier`と一致しないため自然に除外される(誤検知の
//   心配はなく、単に検知対象が広がらないだけ)。
//
// 実装上の注意(RuleRegistryとの関係): このルールは「ファイル内の
// deprecated宣言を集めてから使用箇所を照合する」という2パス処理が必要。
// しかしRuleRegistryに登録されるルールインスタンスは`initialization`で
// 一度だけ生成され、`RunLint`が複数ファイルを処理する間ずっと同じ
// インスタンスが使い回される(RuleDefense001/RuleSec001/RuleSec002は
// ノード単位で独立した判定のみで状態を持たないため問題にならなかった)。
// インスタンスフィールドに「ファイル内で見つけたdeprecated名」を保持すると
// ファイルをまたいで状態が漏れる。これを避けるため、`InterestedNodeTypes`
// を最上位の`root`ノードのみとし、1ファイルにつき1回だけ呼ばれる
// `Check`呼び出しの中で、ローカル変数(ローカルなリスト)を使って
// 自己完結した再帰探索(収集→照合の2パス)を行う設計とした。
// ASTWalker.pas等の共通インフラには一切手を加えていない。

interface

uses
  SysUtils, Generics.Collections, TSBindings, Diagnostics, RuleRegistry;

type
  TRuleDepr001 = class(TInterfacedObject, IRawpacoRule)
  public
    function RuleId: string;
    function Description: string;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

implementation

type
  TDeprecatedNameList = specialize TList<string>; // 大文字化済みの名前を保持

const
  CRuleId = 'RAWPACO-DEPR-001';

function HasDeprecatedAttribute(const AttrNode: TSNode): Boolean;
var
  ChildCount, I: LongWord;
begin
  Result := False;
  ChildCount := ts_node_child_count(AttrNode);
  I := 0;
  while I < ChildCount do
  begin
    if ts_node_type(ts_node_child(AttrNode, I)) = 'kDeprecated' then
      Exit(True);
    Inc(I);
  end;
end;

// 1パス目: declProcを探し、deprecated属性付きのものの名前(大文字化)を集める。
procedure CollectDeprecatedNames(const Node: TSNode; Ctx: TLintContext; Names: TDeprecatedNameList);
var
  ChildCount, I, NamedCount, J: LongWord;
  NameNode, AttrNode: TSNode;
  HasName, IsDeprecated: Boolean;
begin
  if ts_node_type(Node) = 'declProc' then
  begin
    HasName := False;
    NameNode := Node; // ダミー初期値
    IsDeprecated := False;

    ChildCount := ts_node_child_count(Node);
    I := 0;
    while I < ChildCount do
    begin
      if (not HasName) and (ts_node_field_name_for_child(Node, I) = 'name') then
      begin
        NameNode := ts_node_child(Node, I);
        HasName := True;
      end
      else if ts_node_field_name_for_child(Node, I) = 'attribute' then
      begin
        AttrNode := ts_node_child(Node, I);
        // procExternal(cdecl; external;等)はdeprecatedと無関係なので
        // procAttribute型の場合のみ中身を見る。
        if (ts_node_type(AttrNode) = 'procAttribute') and HasDeprecatedAttribute(AttrNode) then
          IsDeprecated := True;
      end;
      Inc(I);
    end;

    // nameが単純なidentifier(ジェネリック名・演算子名ではない)の場合のみ
    // 対象とする。呼び出し側での照合が単純な識別子比較で完結するため。
    if HasName and IsDeprecated and (ts_node_type(NameNode) = 'identifier') then
      Names.Add(UpperCase(Ctx.GetNodeText(NameNode)));
  end;

  // declProcの中(手続き本体)にネストした手続き・関数宣言もPascalでは
  // 可能なため、再帰は打ち切らずに全ノードを辿る。
  NamedCount := ts_node_named_child_count(Node);
  J := 0;
  while J < NamedCount do
  begin
    CollectDeprecatedNames(ts_node_named_child(Node, J), Ctx, Names);
    Inc(J);
  end;
end;

// 2パス目: exprCall(entity=identifier)と、裸のidentifier文を探し、
// 1パス目で集めた名前と一致すれば報告する。
procedure FindUsages(const Node: TSNode; Ctx: TLintContext; Names: TDeprecatedNameList);
var
  NodeType: PAnsiChar;
  ChildCount, I, NamedCount, J: LongWord;
  EntityNode, OnlyChild: TSNode;
  HasEntity: Boolean;
begin
  NodeType := ts_node_type(Node);

  if NodeType = 'exprCall' then
  begin
    HasEntity := False;
    EntityNode := Node; // ダミー初期値
    ChildCount := ts_node_child_count(Node);
    I := 0;
    while I < ChildCount do
    begin
      if ts_node_field_name_for_child(Node, I) = 'entity' then
      begin
        EntityNode := ts_node_child(Node, I);
        HasEntity := True;
        Break;
      end;
      Inc(I);
    end;
    if HasEntity and (ts_node_type(EntityNode) = 'identifier') and
       (Names.IndexOf(UpperCase(Ctx.GetNodeText(EntityNode))) >= 0) then
      Ctx.Report(CRuleId,
        Format('call to "%s", which is declared deprecated in this file', [Ctx.GetNodeText(EntityNode)]),
        EntityNode);
  end
  else if NodeType = 'statement' then
  begin
    // 括弧なし呼び出し(`Foo;`)は、statementの唯一の子が直接identifierになる。
    if ts_node_named_child_count(Node) = 1 then
    begin
      OnlyChild := ts_node_named_child(Node, 0);
      if (ts_node_type(OnlyChild) = 'identifier') and
         (Names.IndexOf(UpperCase(Ctx.GetNodeText(OnlyChild))) >= 0) then
        Ctx.Report(CRuleId,
          Format('call to "%s", which is declared deprecated in this file', [Ctx.GetNodeText(OnlyChild)]),
          OnlyChild);
    end;
  end;

  NamedCount := ts_node_named_child_count(Node);
  J := 0;
  while J < NamedCount do
  begin
    FindUsages(ts_node_named_child(Node, J), Ctx, Names);
    Inc(J);
  end;
end;

function TRuleDepr001.RuleId: string;
begin
  Result := CRuleId;
end;

function TRuleDepr001.Description: string;
begin
  Result := 'call to a procedure/function declared deprecated earlier in the same file';
end;

function TRuleDepr001.InterestedNodeTypes: TStringArray;
begin
  // rootノードのみに関心を持つ(ユニット冒頭コメント参照: ファイル単位の
  // 2パス処理をこの1回のCheck呼び出しの中で完結させ、ルールインスタンスに
  // 状態を持たせない設計のため)。
  Result := TStringArray.Create('root');
end;

procedure TRuleDepr001.Check(const Node: TSNode; Ctx: TLintContext);
var
  Names: TDeprecatedNameList;
begin
  Names := TDeprecatedNameList.Create;
  try
    CollectDeprecatedNames(Node, Ctx, Names);
    if Names.Count > 0 then
      FindUsages(Node, Ctx, Names);
  finally
    Names.Free;
  end;
end;

initialization
  RegisterRule(TRuleDepr001.Create);

end.
