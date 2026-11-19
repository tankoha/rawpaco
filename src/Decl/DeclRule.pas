unit DeclRule;

{$mode objfpc}{$H+}

// 宣言的ルール（RuleFile.TDeclRule）を既存のルール基盤（RuleRegistry.IRawpacoRule）に
// 載せるアダプタと、--rules の読み込み・登録（設計書 OPENGREP_RULE_ENGINE_DESIGN 4.7）。
// InterestedNodeTypes は root だけにして、Check でファイル全体を 1 回照合する。
// RAWPACO-DEPR-001 と同じく、インスタンスにファイルをまたぐ状態を持たせないため。

interface

uses
  SysUtils, Classes, TSBindings, Diagnostics, RuleRegistry, RuleFile;

type
  TDeclRuleAdapter = class(TInterfacedObject, IRawpacoRule)
  private
    // 所有しない。所有者は LoadAndRegisterDeclRules に渡した TDeclRuleList で、
    // lint の実行が終わるまで生かしておくこと。
    FRule: TDeclRule;
  public
    constructor Create(ARule: TDeclRule);
    function RuleId: string;
    function Description: string;
    function Severity: TSeverity;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

// --rules に渡されたパスを、読み込むルールファイルの一覧に展開する。
// ファイルはそのまま、ディレクトリは直下の *.json を名前順（CompareStr）に並べる。
// 再帰はしない（意図しないファイルを拾わないため。必要になったら M3 の YAML と一緒に見直す）。
// 存在しないパスと、*.json が 1 つも無いディレクトリはエラー（黙って何も読まないと、
// ルールを足したのに何も出ないことが安全の意味に誤読されるため。CLAUDE.md ルール5）。
function ExpandRulePaths(const Paths: array of string; out Files: TStringArray;
  out ErrorMessage: string): Boolean;

// Paths を展開して全ファイルを Rules に読み込み、ネイティブのルールと ID が
// 重ならないことを確かめてから、1 ルールにつき 1 個のアダプタを RegisterRule する。
// RuleRegistry.SetRuleFilter（--only / --exclude）より前に呼ぶこと。
// 失敗したら何も登録せずに False を返す。
function LoadAndRegisterDeclRules(const Paths: array of string; Rules: TDeclRuleList;
  Notices: TStrings; out ErrorMessage: string): Boolean;

implementation

uses
  PatMatcher, MsgInterp, Formula;

{ TDeclRuleAdapter }

constructor TDeclRuleAdapter.Create(ARule: TDeclRule);
begin
  inherited Create;
  FRule := ARule;
end;

function TDeclRuleAdapter.RuleId: string;
begin
  Result := FRule.Id;
end;

function TDeclRuleAdapter.Description: string;
begin
  Result := FRule.Message;
end;

function TDeclRuleAdapter.Severity: TSeverity;
begin
  Result := FRule.Severity;
end;

function TDeclRuleAdapter.InterestedNodeTypes: TStringArray;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := 'root';
end;

procedure TDeclRuleAdapter.Check(const Node: TSNode; Ctx: TLintContext);
var
  Matches: TPatMatchArray;
  I, J: Integer;
  Keys, Values: TStringArray;
  B: TMetaVarBinding;
begin
  Matches := EvaluateFormula(FRule.Formula, Node, Ctx.Source);
  for I := 0 to High(Matches) do
  begin
    // 同じ範囲でも束縛の違う一致が複数残りうる（pattern-inside が複数の外側と
    // 両立したときなど）が、利用者には同じ箇所の重複に見えるので 1 件だけ報告する。
    // EvaluateFormula が範囲順に並べるので、直前と比べれば足りる。
    if (I > 0) and (Matches[I].StartByte = Matches[I - 1].StartByte) and
       (Matches[I].EndByte = Matches[I - 1].EndByte) then
      Continue;
    Keys := nil;
    Values := nil;
    SetLength(Keys, Length(Matches[I].Bindings));
    SetLength(Values, Length(Matches[I].Bindings));
    for J := 0 to High(Matches[I].Bindings) do
    begin
      B := Matches[I].Bindings[J];
      Keys[J] := BindingKey(B.Name, B.IsRange);
      Values[J] := BindingText(B, Ctx.Source);
    end;
    Ctx.ReportAt(FRule.Id, FRule.Severity, InterpolateMessage(FRule.Message, Keys, Values),
      Matches[I].StartPoint);
  end;
end;

{ ExpandRulePaths }

function ExpandRulePaths(const Paths: array of string; out Files: TStringArray;
  out ErrorMessage: string): Boolean;
var
  I, J, K: Integer;
  P, DirPath, Pattern, SwapVal: string;
  SR: TSearchRec;
  Temp: TStringArray;
begin
  Result := True;
  ErrorMessage := '';
  SetLength(Files, 0);

  for I := 0 to High(Paths) do
  begin
    P := Paths[I];
    if DirectoryExists(P) then
    begin
      DirPath := IncludeTrailingPathDelimiter(P);
      Pattern := DirPath + '*.json';
      SetLength(Temp, 0);
      if FindFirst(Pattern, faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Attr and faDirectory) = 0 then
          begin
            SetLength(Temp, Length(Temp) + 1);
            Temp[High(Temp)] := DirPath + SR.Name;
          end;
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
      if Length(Temp) = 0 then
      begin
        ErrorMessage := P + ': no *.json rule files in the directory';
        Result := False;
        Exit;
      end;
      // TStringList.Sort はロケール依存の比較になるため、
      // Windows / Linux で同じ順序を保証するために CompareStr で挿入ソートする
      for J := 1 to High(Temp) do
      begin
        K := J;
        while (K > 0) and (CompareStr(Temp[K], Temp[K - 1]) < 0) do
        begin
          SwapVal := Temp[K];
          Temp[K] := Temp[K - 1];
          Temp[K - 1] := SwapVal;
          Dec(K);
        end;
      end;
      for J := 0 to High(Temp) do
      begin
        SetLength(Files, Length(Files) + 1);
        Files[High(Files)] := Temp[J];
      end;
    end
    else if FileExists(P) then
    begin
      SetLength(Files, Length(Files) + 1);
      Files[High(Files)] := P;
    end
    else
    begin
      ErrorMessage := P + ': no such file or directory';
      Result := False;
      Exit;
    end;
  end;
end;

{ LoadAndRegisterDeclRules }

function LoadAndRegisterDeclRules(const Paths: array of string; Rules: TDeclRuleList;
  Notices: TStrings; out ErrorMessage: string): Boolean;
var
  Files: TStringArray;
  BuiltinIds: TStringArray;
  I, J: Integer;
  Err: string;
  Dup: Boolean;
begin
  Result := False;
  ErrorMessage := '';

  if not ExpandRulePaths(Paths, Files, ErrorMessage) then
    Exit;

  for I := 0 to High(Files) do
  begin
    if not LoadRulesFromFile(Files[I], Rules, Notices, Err) then
    begin
      ErrorMessage := Err;
      Exit;
    end;
  end;

  // 大文字小文字だけが違う ID も、--only の指定や出力の読み手にとって紛らわしいので衝突とみなす。
  // 1 件でも衝突すれば何も登録しない。
  BuiltinIds := RuleRegistry.AllRuleIds;
  for I := 0 to Rules.Count - 1 do
  begin
    Dup := False;
    for J := 0 to High(BuiltinIds) do
    begin
      if SameText(Rules[I].Id, BuiltinIds[J]) then
      begin
        Dup := True;
        Break;
      end;
    end;
    if Dup then
    begin
      ErrorMessage := Format('%s: rule id "%s" is already used by a built-in rule',
        [Rules[I].SourceFile, Rules[I].Id]);
      Exit;
    end;
  end;

  for I := 0 to Rules.Count - 1 do
    RuleRegistry.RegisterRule(TDeclRuleAdapter.Create(Rules[I]));

  Result := True;
end;

end.
