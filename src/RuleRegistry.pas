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
    // 設計書4.1.1節。ルール自身の性質として固定される重要度(CLIやrawpaco.json
    // からの上書きは設けない。理由は4.1.1/4.1.6節参照)。将来の--list-rules的な
    // ツーリング向けにRuleId/Descriptionと並べてintrospectable にしておく。
    function Severity: TSeverity;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

  TRuleList = specialize TList<IRawpacoRule>;

procedure RegisterRule(const Rule: IRawpacoRule);
procedure DispatchNode(const Node: TSNode; Ctx: TLintContext);

// 登録済み全ルールのIDを重複なく返す(登録順)。--only/--exclude が指定した
// IDの実在確認、およびエラーメッセージでの既知ID列挙に使う。
function AllRuleIds: TStringArray;

// --only/--exclude によるルールの有効・無効を設定する。OnlyIds/ExcludeIds
// のどちらか一方だけを渡すこと(両方非空にする/しないの判断は呼び出し側の
// rawpaco.lprが行う。このユニットはCLIオプションの存在を知らない)。
// 未知のルールIDが含まれる場合はFalseを返しErrorMsgに理由を入れる
// (rawpaco.jsonの未知キーと同じ方針: タイプミスを黙って無視しない。
// CLAUDE.mdルール5)。
function SetRuleFilter(const OnlyIds, ExcludeIds: TStringArray;
  out ErrorMsg: string): Boolean;

implementation

type
  TDispatchTable = specialize TDictionary<string, TRuleList>;
  TFilterMode = (fmNone, fmOnly, fmExclude);

var
  GDispatch: TDispatchTable;
  GAllRules: TRuleList;
  GFilterMode: TFilterMode = fmNone;
  GFilterIds: TStringArray;

function IdInArray(const Id: string; const Arr: TStringArray): Boolean;
var
  S: string;
begin
  Result := False;
  for S in Arr do
    if S = Id then
      Exit(True);
end;

procedure RegisterRule(const Rule: IRawpacoRule);
var
  NodeType: string;
  List: TRuleList;
begin
  GAllRules.Add(Rule);
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

function RuleIsEnabled(const Id: string): Boolean;
begin
  case GFilterMode of
    fmOnly:    Result := IdInArray(Id, GFilterIds);
    fmExclude: Result := not IdInArray(Id, GFilterIds);
  else
    Result := True;
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
      if RuleIsEnabled(Rule.RuleId) then
        Rule.Check(Node, Ctx);
end;

function AllRuleIds: TStringArray;
var
  I: Integer;
  Ids: TStringArray;
begin
  SetLength(Ids, GAllRules.Count);
  for I := 0 to GAllRules.Count - 1 do
    Ids[I] := GAllRules[I].RuleId;
  Result := Ids;
end;

function SetRuleFilter(const OnlyIds, ExcludeIds: TStringArray;
  out ErrorMsg: string): Boolean;
var
  Known: TStringArray;
  Id: string;
begin
  ErrorMsg := '';
  Known := AllRuleIds;

  for Id in OnlyIds do
    if not IdInArray(Id, Known) then
    begin
      ErrorMsg := Format('unknown rule id in --only: %s', [Id]);
      Exit(False);
    end;
  for Id in ExcludeIds do
    if not IdInArray(Id, Known) then
    begin
      ErrorMsg := Format('unknown rule id in --exclude: %s', [Id]);
      Exit(False);
    end;

  if Length(OnlyIds) > 0 then
  begin
    GFilterMode := fmOnly;
    GFilterIds := OnlyIds;
  end
  else if Length(ExcludeIds) > 0 then
  begin
    GFilterMode := fmExclude;
    GFilterIds := ExcludeIds;
  end
  else
    GFilterMode := fmNone;

  Result := True;
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
  GAllRules := TRuleList.Create;

finalization
  FreeDispatchTable;
  GAllRules.Free;

end.
