unit RuleRegistry;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Generics.Collections, TSBindings, Diagnostics;

type
  // InterestedNodeTypesの戻り値には独自の配列型を定義せず、SysUtilsが既に
  // 公開しているTStringArray(= array of string, syshelph.inc由来)を再利用する。
  // このユニットを含め全ユニットがSysUtilsを使う以上、同名の型を再定義すると
  // 曖昧な識別子エラーの火種になるため。
  IRawpacoRule = interface
    function RuleId: string;
    function Description: string;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

  TRuleList = specialize TList<IRawpacoRule>;

procedure RegisterRule(const Rule: IRawpacoRule);
procedure DispatchNode(const Node: TSNode; Ctx: TLintContext);

implementation

type
  TDispatchTable = specialize TDictionary<string, TRuleList>;

var
  GDispatch: TDispatchTable;

procedure RegisterRule(const Rule: IRawpacoRule);
var
  NodeType: string;
  List: TRuleList;
begin
  for NodeType in Rule.InterestedNodeTypes do
  begin
    if not GDispatch.TryGetValue(NodeType, List) then
    begin
      List := TRuleList.Create;
      GDispatch.Add(NodeType, List);
    end;
    List.Add(Rule);
  end;
end;

procedure DispatchNode(const Node: TSNode; Ctx: TLintContext);
var
  List: TRuleList;
  Rule: IRawpacoRule;
begin
  // ts_node_typeが返すPAnsiCharは、Dictionaryのキー検索時にAnsiStringへ
  // 暗黙変換される。
  if GDispatch.TryGetValue(ts_node_type(Node), List) then
    for Rule in List do
      Rule.Check(Node, Ctx);
end;

procedure FreeDispatchTable;
var
  Bucket: TRuleList;
begin
  // TDictionaryはvalue側のTListを自動解放しないため、各バケットを
  // 明示的にFreeしてからDictionary自体をFreeする。
  for Bucket in GDispatch.Values do
    Bucket.Free;
  GDispatch.Free;
end;

initialization
  GDispatch := TDispatchTable.Create;

finalization
  FreeDispatchTable;

end.
