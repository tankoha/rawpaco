unit ASTWalker;

{$mode objfpc}{$H+}

interface

uses
  TSBindings, Diagnostics, RuleRegistry;

procedure WalkTree(const Node: TSNode; Ctx: TLintContext);

implementation

procedure WalkTree(const Node: TSNode; Ctx: TLintContext);
var
  Count, I: LongWord;
begin
  DispatchNode(Node, Ctx);

  // ts_node_named_child_countはLongWord(符号なし)を返すため、
  // "for I := 0 to Count - 1 do" は子が0個のノードで 0 - 1 が
  // 4294967295 にアンダーフローし、範囲外アクセスでEAccessViolationを
  // 起こす(実装前の検証で実際に再現した)。whileで安全に書く。
  Count := ts_node_named_child_count(Node);
  I := 0;
  while I < Count do
  begin
    WalkTree(ts_node_named_child(Node, I), Ctx);
    Inc(I);
  end;
end;

end.
