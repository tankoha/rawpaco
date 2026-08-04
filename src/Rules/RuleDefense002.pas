unit RuleDefense002;

{$mode objfpc}{$H+}

// RAWPACO-DEFENSE-002: オブジェクト生成直後の無意味なnilチェック検知。
// docs/RULE_ENGINE_DESIGN.md P8/2.2節に対応。`Obj := TFoo.Create;` の
// 直後の文が `if Assigned(Obj) then ...` である場合を検知する。FPCの
// コンストラクタは例外を送出しない限りnilを返さないため、この直後チェックは
// 常に真になり無意味(誤検知回避のため「直後」を同一ブロック内で隣接する
// 2文に限定する。設計書もこの狭いスコープを推奨している)。
//
// tree-sitter-pascal(v0.10.2)の実際の文法(vendor/tree-sitter-pascal/
// src/node-types.json・grammar.jsで確認済み。実際にプローブプログラムを
// ビルドして生きた検証も行った):
//
// - `begin...end`は`block`ノード、try/repeat等の本体は`statements`ノード
//   という別種別になるが、いずれもフィールド名を持たず`assignment`/`if`/
//   `ifElse`/`statement`等が直接並ぶ点は同じ(P4の`RuleDepr001.pas`で
//   確認した構造と同様)。よってこのルールは両方のノード種別に関心を持ち、
//   その場でNAMED子を2つずつペアにして走査する。
// - `Obj := TFoo.Create;`(括弧なし)は`assignment`のrhsが**`exprDot`**
//   (lhs=identifier"TFoo", rhs=identifier"Create")になる。
//   `Obj := TFoo.Create();`(括弧あり)は`assignment`のrhsが`exprCall`
//   (entity=`exprDot`)になる。両方の形を扱う必要がある。
// - `if`ノードは`condition`/`then`フィールドを持つ(elseなし)。elseがある
//   場合は`ifElse`という別ノード種別になり`condition`/`then`/`else`を
//   持つ。elseの有無に関わらず「直後チェックが常に真」という無意味さは
//   変わらないため、両方を対象にする。
// - `Assigned(Obj)`は`exprCall`(entity=identifier"Assigned",
//   args=exprArgs(identifier"Obj"))になる。
//
// 誤検知の残る余地(意図的なスコープ、CLAUDE.mdルール8): 型解決を行わない
// ため、「.Create」という名前のメソッドが本当にコンストラクタかどうかは
// 判定できない(例えばファクトリメソッドが同名で偶然nilを返す可能性を
// 排除できない)。ただしObject Pascalでは「.Create」=コンストラクタという
// 命名慣習が非常に強く、設計書もこのヒューリスティックを前提としている。

interface

uses
  SysUtils, TSBindings, Diagnostics, RuleRegistry;

type
  TRuleDefense002 = class(TInterfacedObject, IRawpacoRule)
  public
    function RuleId: string;
    function Description: string;
    function Severity: TSeverity;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

implementation

const
  CRuleId = 'RAWPACO-DEFENSE-002';
  // 設計書4.1.2節: DEFENSE-001と異なり失敗を握りつぶしてはいない。単に
  // 冗長なコードというだけなので、既定ではCIを落とさないWarning階層。
  CSeverity = svWarning;

// assignmentのrhsノードが `<何か>.Create` または `<何か>.Create(...)` の
// 形かどうかを見る(括弧の有無で exprDot 直接 / exprCall 経由 の2パターン
// になる。ユニット冒頭コメント参照)。
function IsCreateCall(const RhsNode: TSNode; Ctx: TLintContext): Boolean;
var
  ChildCount, I: LongWord;
  EntityNode, DotNode, DotRhsNode: TSNode;
  HasEntity, HasDotRhs: Boolean;
  NodeType: PAnsiChar;
begin
  Result := False;
  NodeType := ts_node_type(RhsNode);

  if NodeType = 'exprDot' then
    DotNode := RhsNode
  else if NodeType = 'exprCall' then
  begin
    HasEntity := False;
    EntityNode := RhsNode; // ダミー初期値
    ChildCount := ts_node_child_count(RhsNode);
    I := 0;
    while I < ChildCount do
    begin
      if ts_node_field_name_for_child(RhsNode, I) = 'entity' then
      begin
        EntityNode := ts_node_child(RhsNode, I);
        HasEntity := True;
        Break;
      end;
      Inc(I);
    end;
    if not (HasEntity and (ts_node_type(EntityNode) = 'exprDot')) then
      Exit; // Foo()のような単純呼び出しはexprDotを経由しないため対象外
    DotNode := EntityNode;
  end
  else
    Exit; // 単純呼び出しでも.呼び出しでもない(定数・別の式等)は対象外

  HasDotRhs := False;
  DotRhsNode := DotNode; // ダミー初期値
  ChildCount := ts_node_child_count(DotNode);
  I := 0;
  while I < ChildCount do
  begin
    if ts_node_field_name_for_child(DotNode, I) = 'rhs' then
    begin
      DotRhsNode := ts_node_child(DotNode, I);
      HasDotRhs := True;
      Break;
    end;
    Inc(I);
  end;

  Result := HasDotRhs and (ts_node_type(DotRhsNode) = 'identifier') and
    (UpperCase(Ctx.GetNodeText(DotRhsNode)) = 'CREATE');
end;

// assignmentノードが`<identifier> := <何か>.Create(...)`の形であれば、
// 代入先の識別子名(大文字化)を返す。当てはまらなければFalse。
function TryGetCreateAssignmentTarget(const AssignNode: TSNode; Ctx: TLintContext;
  out TargetNameUpper: string): Boolean;
var
  ChildCount, I: LongWord;
  LhsNode, RhsNode: TSNode;
  HasLhs, HasRhs: Boolean;
begin
  Result := False;
  HasLhs := False;
  HasRhs := False;
  LhsNode := AssignNode; // ダミー初期値
  RhsNode := AssignNode;

  ChildCount := ts_node_child_count(AssignNode);
  I := 0;
  while I < ChildCount do
  begin
    if ts_node_field_name_for_child(AssignNode, I) = 'lhs' then
    begin
      LhsNode := ts_node_child(AssignNode, I);
      HasLhs := True;
    end
    else if ts_node_field_name_for_child(AssignNode, I) = 'rhs' then
    begin
      RhsNode := ts_node_child(AssignNode, I);
      HasRhs := True;
    end;
    Inc(I);
  end;

  if not (HasLhs and HasRhs) then
    Exit;
  // lhsが単純な識別子の場合のみ対象(exprDot経由のフィールド代入等はP1〜P7
  // でも一貫して対象外としてきたスコープ限定と同じ方針)。
  if ts_node_type(LhsNode) <> 'identifier' then
    Exit;
  if not IsCreateCall(RhsNode, Ctx) then
    Exit;

  TargetNameUpper := UpperCase(Ctx.GetNodeText(LhsNode));
  Result := True;
end;

// if/ifElseノードの条件が`Assigned(<識別子>)`の形であれば、その識別子名
// (大文字化)を返す。当てはまらなければFalse。
function TryGetAssignedCheckTarget(const IfNode: TSNode; Ctx: TLintContext;
  out TargetNameUpper: string): Boolean;
var
  ChildCount, I: LongWord;
  ConditionNode, EntityNode, ArgsNode, ArgNode: TSNode;
  HasCondition, HasEntity, HasArgs: Boolean;
begin
  Result := False;
  HasCondition := False;
  ConditionNode := IfNode; // ダミー初期値
  ChildCount := ts_node_child_count(IfNode);
  I := 0;
  while I < ChildCount do
  begin
    if ts_node_field_name_for_child(IfNode, I) = 'condition' then
    begin
      ConditionNode := ts_node_child(IfNode, I);
      HasCondition := True;
      Break;
    end;
    Inc(I);
  end;
  if not (HasCondition and (ts_node_type(ConditionNode) = 'exprCall')) then
    Exit;

  HasEntity := False;
  HasArgs := False;
  EntityNode := ConditionNode; // ダミー初期値
  ArgsNode := ConditionNode;
  ChildCount := ts_node_child_count(ConditionNode);
  I := 0;
  while I < ChildCount do
  begin
    if ts_node_field_name_for_child(ConditionNode, I) = 'entity' then
    begin
      EntityNode := ts_node_child(ConditionNode, I);
      HasEntity := True;
    end
    else if ts_node_field_name_for_child(ConditionNode, I) = 'args' then
    begin
      ArgsNode := ts_node_child(ConditionNode, I);
      HasArgs := True;
    end;
    Inc(I);
  end;

  if not (HasEntity and (ts_node_type(EntityNode) = 'identifier') and
          (UpperCase(Ctx.GetNodeText(EntityNode)) = 'ASSIGNED')) then
    Exit;
  // Assigned(X)は引数がちょうど1つの単純な識別子である場合のみ対象とする
  // (Assigned(Obj.Field)のような複雑な式は対象外、誤検知回避のため)。
  if not (HasArgs and (ts_node_named_child_count(ArgsNode) = 1)) then
    Exit;
  ArgNode := ts_node_named_child(ArgsNode, 0);
  if ts_node_type(ArgNode) <> 'identifier' then
    Exit;

  TargetNameUpper := UpperCase(Ctx.GetNodeText(ArgNode));
  Result := True;
end;

function TRuleDefense002.RuleId: string;
begin
  Result := CRuleId;
end;

function TRuleDefense002.Severity: TSeverity;
begin
  Result := CSeverity;
end;

function TRuleDefense002.Description: string;
begin
  Result := 'redundant Assigned() check immediately after a constructor call (FPC constructors do not return nil)';
end;

function TRuleDefense002.InterestedNodeTypes: TStringArray;
begin
  // `begin...end`ブロックは`block`、try/repeat等の本体は`statements`と
  // 別ノード種別になるが、子の並び方(assignment/if/ifElse等が直接並ぶ)は
  // 同じなので両方を対象にする(node-types.jsonで確認済み)。
  Result := TStringArray.Create('block', 'statements');
end;

procedure TRuleDefense002.Check(const Node: TSNode; Ctx: TLintContext);
var
  Count, I: LongWord;
  Current, Next: TSNode;
  NextType: PAnsiChar;
  AssignTarget, CheckTarget: string;
begin
  Count := ts_node_named_child_count(Node);
  if Count < 2 then
    Exit;

  I := 0;
  while I < Count - 1 do // 隣接ペアを見るのでCount-1回で十分。Countは
                         // LongWord(符号なし)だがCount>=2をここまでの
                         // Exitで保証済みなのでCount-1のアンダーフローは
                         // 起きない(ASTWalker.pas参照)。
  begin
    Current := ts_node_named_child(Node, I);
    if ts_node_type(Current) = 'assignment' then
    begin
      Next := ts_node_named_child(Node, I + 1);
      NextType := ts_node_type(Next);
      if (NextType = 'if') or (NextType = 'ifElse') then
      begin
        if TryGetCreateAssignmentTarget(Current, Ctx, AssignTarget) and
           TryGetAssignedCheckTarget(Next, Ctx, CheckTarget) and
           (AssignTarget = CheckTarget) then
          Ctx.Report(CRuleId, CSeverity,
            'Assigned() check right after a constructor call is always true and can be removed',
            Next);
      end;
    end;
    Inc(I);
  end;
end;

initialization
  RegisterRule(TRuleDefense002.Create);

end.
