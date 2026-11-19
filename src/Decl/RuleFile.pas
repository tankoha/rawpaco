unit RuleFile;

{$mode objfpc}{$H+}

// 宣言的ルールのファイル（JSON）を読み込み、ルールごとにパターンをコンパイルする
// （設計書 4.6 節）。YAML は M3 で自作のサブセットを足す予定で、M1 は fpjson で
// 読める JSON だけを受け付ける（未決 #7。JSON 先行は確定）。形は opengrep の YAML を
// そのまま JSON にしたもの: {"rules": [{"id": ..., "message": ..., ...}]}。
//
// 読み込みの方針（CLAUDE.md ルール5）:
// - 未知のキー、まだ実装していない機能のキー、rawpaco が対象外にした機能のキーは、
//   どれも読み込みエラーにする。黙って飛ばすと「ルールを足したのに何も出ない」が
//   安全の意味に誤読されるため
// - `languages` に "pascal" が無いルールだけは、エラーにせず飛ばして通知を 1 行積む。
//   多言語のルール集をそのまま渡せるようにするため（設計書 4.6）
// - 1 ファイルの読み込みは全か無か。途中でエラーになったら、そのファイルのルールは
//   1 件も Rules に足さない

interface

uses
  SysUtils, Classes, Diagnostics, PatLexer, PatCompiler, Formula;

type
  TDeclRule = class
  private
    FId: string;
    FMessage: string;
    FSeverity: TSeverity;
    FFormula: TFormula;
    FLexOptions: TPatLexOptions;
    FGoDeeperStmt: Boolean;
    FSourceFile: string;
  public
    // Formula を解放する。
    destructor Destroy; override;
    property Id: string read FId write FId;
    // `$X` の補間前の文字列（補間は M1 の別タスク）。
    property Message: string read FMessage write FMessage;
    property Severity: TSeverity read FSeverity write FSeverity;
    // `pattern` / `patterns` / `pattern-either` を読んだ木（根は正の項）。所有者はこのオブジェクト。
    property Formula: TFormula read FFormula write FFormula;
    property LexOptions: TPatLexOptions read FLexOptions write FLexOptions;
    // `options: { go_deeper_stmt: false }`（未決 #4 の決定。既定は True）。
    // 効くのは文の並びのパターンを実装する M2 から。
    property GoDeeperStmt: Boolean read FGoDeeperStmt write FGoDeeperStmt;
    // 読み込んだファイルのパス（エラー表示と、将来の出力でネイティブのルールと区別するため）。
    property SourceFile: string read FSourceFile write FSourceFile;
  end;

  // 読み込んだルールの一覧。要素の所有者はこのリスト。
  TDeclRuleList = class
  private
    FItems: array of TDeclRule;
    function GetCount: Integer;
    function GetItem(Index: Integer): TDeclRule;
  public
    destructor Destroy; override;
    procedure Add(Rule: TDeclRule);
    // 完全一致で探す。無ければ nil。
    function FindById(const Id: string): TDeclRule;
    property Count: Integer read GetCount;
    property Items[Index: Integer]: TDeclRule read GetItem; default;
  end;

// Text を JSON のルールファイルとして読み、成功したルールを Rules の末尾に足す。
// SourceName はエラー表示と TDeclRule.SourceFile に使う名前。
// 失敗したら False を返し、ErrorMessage に 1 件だけ理由を入れる（Rules は変えない）。
// Notices には、飛ばしたルールの通知とパターンの警告を 1 行ずつ足す（nil なら捨てる）。
// ID の重複は、Rules に既にあるものとの間でも、同じファイルの中でもエラーにする。
function LoadRulesFromText(const Text, SourceName: string; Rules: TDeclRuleList;
  Notices: TStrings; out ErrorMessage: string): Boolean;

// ファイルを読んで LoadRulesFromText に渡す。読めなければエラー。
function LoadRulesFromFile(const FileName: string; Rules: TDeclRuleList;
  Notices: TStrings; out ErrorMessage: string): Boolean;

// ゴールデンテスト用のテキスト表現（開発者向けオプション --dump-rules）。
function DumpRules(Rules: TDeclRuleList): string;

implementation

uses
  fpjson, jsonparser, LintDriver, MsgInterp;

const
  CAcceptedKeys: array[0..11] of string =
    ('id', 'message', 'severity', 'languages', 'pattern', 'metadata', 'options',
     'patterns', 'pattern-either', 'pattern-not', 'pattern-inside', 'pattern-not-inside');
  CNotImplKeys: array[0..8] of string =
    ('pattern-regex', 'pattern-not-regex',
     'metavariable-regex', 'metavariable-pattern', 'metavariable-comparison',
     'focus-metavariable', 'paths', 'fix', 'fix-regex');
  COutOfScopeKeys: array[0..15] of string =
    ('mode', 'pattern-sources', 'pattern-sinks', 'pattern-sanitizers',
     'pattern-propagators', 'taint', 'metavariable-type', 'join', 'extract',
     'dest-language', 'dest-rule-kind', 'reduce', 'match', 'equivalences',
     'project-depends-on', 'r2c-internal-project-depends-on');


destructor TDeclRule.Destroy;
begin
  FFormula.Free;
  inherited Destroy;
end;


function TDeclRuleList.GetCount: Integer;
begin
  Result := Length(FItems);
end;

function TDeclRuleList.GetItem(Index: Integer): TDeclRule;
begin
  Result := FItems[Index];
end;

destructor TDeclRuleList.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    FItems[I].Free;
  inherited Destroy;
end;

procedure TDeclRuleList.Add(Rule: TDeclRule);
var
  N: Integer;
begin
  N := Length(FItems);
  SetLength(FItems, N + 1);
  FItems[N] := Rule;
end;

function TDeclRuleList.FindById(const Id: string): TDeclRule;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(FItems) do
    if FItems[I].Id = Id then
    begin
      Result := FItems[I];
      Exit;
    end;
end;


function InArray(const S: string; const Arr: TStringArray): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(Arr) do
    if Arr[I] = S then
      Exit(True);
end;

function IsValidId(const S: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  if S = '' then
  begin
    Result := False;
    Exit;
  end;
  Result := True;
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if not (C in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.']) then
    begin
      Result := False;
      Exit;
    end;
  end;
end;

function CheckKey(const Key, Prefix: string; out ErrMsg: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(CAcceptedKeys) do
    if CAcceptedKeys[I] = Key then
    begin
      Result := True;
      Exit;
    end;
  for I := 0 to High(CNotImplKeys) do
    if CNotImplKeys[I] = Key then
    begin
      ErrMsg := Prefix + ': "' + Key + '" is not supported yet';
      Exit(False);
    end;
  for I := 0 to High(COutOfScopeKeys) do
    if COutOfScopeKeys[I] = Key then
    begin
      ErrMsg := Prefix + ': "' + Key + '" is not supported by rawpaco (out of scope)';
      Exit(False);
    end;
  ErrMsg := Prefix + ': unknown key "' + Key + '"';
  Result := False;
end;


function LoadRulesFromFile(const FileName: string; Rules: TDeclRuleList;
  Notices: TStrings; out ErrorMessage: string): Boolean;
var
  FileText: AnsiString;
begin
  if not FileExists(FileName) then
  begin
    ErrorMessage := FileName + ': cannot read the file';
    Result := False;
    Exit;
  end;
  FileText := LintDriver.ReadFileAsString(FileName);
  Result := LoadRulesFromText(FileText, FileName, Rules, Notices, ErrorMessage);
end;


function KindForKey(const Key: string; out Kind: TFormulaKind): Boolean;
begin
  Result := True;
  Kind := fkPattern;
  if Key = 'pattern' then
    Kind := fkPattern
  else if Key = 'patterns' then
    Kind := fkPatterns
  else if Key = 'pattern-either' then
    Kind := fkEither
  else if Key = 'pattern-not' then
    Kind := fkNot
  else if Key = 'pattern-inside' then
    Kind := fkInside
  else if Key = 'pattern-not-inside' then
    Kind := fkNotInside
  else
    Result := False;
end;

// Value を Kind の演算子の値として読む。Path はエラー表示用の位置
// （例: `"patterns"[1]."pattern-not"`）。失敗したら F = nil で、ErrMsg は Path から始まる。
// pattern-either の中に否定や inside を置くのは、opengrep では書けても意味が
// 分かりにくく、M2 の差分テストで挙動を確かめるまでは受け付けない（CLAUDE.md ルール5）。
function ParseFormula(Value: TJSONData; Kind: TFormulaKind; const Path: string;
  const LexOpts: TPatLexOptions; Notices: TStrings; const NoticePrefix: string;
  out F: TFormula; out ErrMsg: string): Boolean;
var
  CR: TPatCompileResult;
  Arr: TJSONArray;
  Elem: TJSONObject;
  I, W: Integer;
  Key, ElemPath: string;
  ChildKind: TFormulaKind;
  Child: TFormula;
  HasPositive: Boolean;
begin
  F := nil;
  ErrMsg := '';
  if Kind in [fkPatterns, fkEither] then
  begin
    if (Value.JSONType <> jtArray) or (TJSONArray(Value).Count = 0) then
    begin
      ErrMsg := Path + ': expected a non-empty array';
      Exit(False);
    end;
    Arr := TJSONArray(Value);
    F := TFormula.CreateNode(Kind);
    HasPositive := False;
    for I := 0 to Arr.Count - 1 do
    begin
      ElemPath := Path + '[' + IntToStr(I) + ']';
      if (Arr.Items[I].JSONType <> jtObject) or (TJSONObject(Arr.Items[I]).Count <> 1) then
        ErrMsg := ElemPath + ': expected an object with exactly one key'
      else
      begin
        Elem := TJSONObject(Arr.Items[I]);
        Key := Elem.Names[0];
        if not KindForKey(Key, ChildKind) then
        begin
          // CheckKey が通すのはルールの直下にだけ書けるキー（id など）なので、ここでは未知。
          if CheckKey(Key, ElemPath, ErrMsg) then
            ErrMsg := ElemPath + ': unknown key "' + Key + '"';
        end
        else if (Kind = fkEither) and not IsPositiveKind(ChildKind) then
          ErrMsg := ElemPath + ': "' + Key + '" is not allowed in "pattern-either" (only in "patterns")'
        else if ParseFormula(Elem.Items[0], ChildKind, ElemPath + '."' + Key + '"',
          LexOpts, Notices, NoticePrefix, Child, ErrMsg) then
        begin
          F.AddChild(Child);
          if IsPositiveKind(ChildKind) then
            HasPositive := True;
        end;
      end;
      if ErrMsg <> '' then
      begin
        FreeAndNil(F);
        Exit(False);
      end;
    end;
    // 否定と inside だけの patterns は、opengrep でも正の項が必須（設計書 4.4）。
    if (Kind = fkPatterns) and not HasPositive then
    begin
      ErrMsg := Path + ': needs at least one "pattern", "patterns" or "pattern-either"';
      FreeAndNil(F);
      Exit(False);
    end;
    Exit(True);
  end;

  if (Value.JSONType <> jtString) or (Value.AsString = '') then
  begin
    ErrMsg := Path + ': expected a non-empty string';
    Exit(False);
  end;
  CR := CompilePattern(Value.AsString, LexOpts);
  if not CR.Ok then
  begin
    ErrMsg := Path + ': ' + CR.ErrorMessage;
    Exit(False);
  end;
  if CR.Root.Kind = pkSequence then
  begin
    // 照合器（PatMatcher.FindMatches）は文の並びをまだ扱わず空の結果を返す。
    // 読み込めてしまうと「何も出ない」が安全の意味に読まれるので、ここで止める。
    CR.Root.Free;
    ErrMsg := Path + ': a sequence of statements is not supported yet';
    Exit(False);
  end;
  if Notices <> nil then
    for W := 0 to High(CR.Warnings) do
      Notices.Add(NoticePrefix + ': warning: ' + CR.Warnings[W]);
  F := TFormula.CreateLeaf(Kind, CR);
  Result := True;
end;


// 検査の順序は設計書 4.6 と tests/decl/load の期待値が前提にしている。id を最初に読むのは、
// 以降のエラーに id を添えて、どのルールかを利用者が探せるようにするため。
function LoadOneRule(Obj: TJSONObject; const SrcName: string; AIndex: Integer;
  out Rule: TDeclRule; out ErrMsg: string; Notices: TStrings;
  out Skipped: Boolean): Boolean;
var
  I, J: Integer;
  Key: string;
  Prefix: string;
  RuleId: string;
  Found: Boolean;
  LangArr: TJSONArray;
  HasPascal: Boolean;
  SevVal: string;
  Sev: TSeverity;
  MsgVal: string;
  OptObj: TJSONObject;
  LexOpts: TPatLexOptions;
  GoDeeper: Boolean;
  FormulaCount, FormulaIdx: Integer;
  RootKind: TFormulaKind;
  Form: TFormula;
  BoundVars, BoundEllipses: TStringArray;
  W: Integer;
  Refs: TMsgVarRefArray;
  Warned: TStringArray;
  RefBound: Boolean;
  RefText: string;
begin
  Rule := nil;
  ErrMsg := '';
  Skipped := False;

  Found := False;
  for I := 0 to Obj.Count - 1 do
  begin
    if Obj.Names[I] = 'id' then
    begin
      Found := True;
      if Obj.Items[I].JSONType <> jtString then
      begin
        ErrMsg := SrcName + ': rules[' + IntToStr(AIndex) + ']: "id": expected a string';
        Exit(False);
      end;
      RuleId := Obj.Items[I].AsString;
      if not IsValidId(RuleId) then
      begin
        ErrMsg := SrcName + ': rules[' + IntToStr(AIndex) +
          ']: "id": must be non-empty and contain only letters, digits, "_", "-" and "."';
        Exit(False);
      end;
      Break;
    end;
  end;
  if not Found then
  begin
    ErrMsg := SrcName + ': rules[' + IntToStr(AIndex) + ']: "id" is missing';
    Exit(False);
  end;


  Prefix := SrcName + ': rules[' + IntToStr(AIndex) + '] (id "' + RuleId + '")';

  for I := 0 to Obj.Count - 1 do
  begin
    Key := Obj.Names[I];
    if not CheckKey(Key, Prefix, ErrMsg) then
      Exit(False);
  end;

  Found := False;
  for I := 0 to Obj.Count - 1 do
  begin
    if Obj.Names[I] = 'languages' then
    begin
      Found := True;
      if (Obj.Items[I].JSONType <> jtArray) or (TJSONArray(Obj.Items[I]).Count = 0) then
      begin
        ErrMsg := Prefix + ': "languages": expected a non-empty array of strings';
        Exit(False);
      end;
      LangArr := TJSONArray(Obj.Items[I]);
      HasPascal := False;
      for J := 0 to LangArr.Count - 1 do
      begin
        if LangArr.Items[J].JSONType <> jtString then
        begin
          ErrMsg := Prefix + ': "languages": expected a non-empty array of strings';
          Exit(False);
        end;
        if LangArr.Items[J].AsString = 'pascal' then
        begin
          HasPascal := True;
        end;
      end;
      if not HasPascal then
      begin
        if Notices <> nil then
          Notices.Add(Prefix + ': skipped: "languages" does not include "pascal"');
        Skipped := True;
        Exit(False);
      end;
      Break;
    end;
  end;
  if not Found then
  begin
    ErrMsg := Prefix + ': "languages" is missing';
    Exit(False);
  end;

  Found := False;
  for I := 0 to Obj.Count - 1 do
  begin
    if Obj.Names[I] = 'message' then
    begin
      Found := True;
      if (Obj.Items[I].JSONType <> jtString) or (Obj.Items[I].AsString = '') then
      begin
        ErrMsg := Prefix + ': "message": expected a non-empty string';
        Exit(False);
      end;
      MsgVal := Obj.Items[I].AsString;
      Break;
    end;
  end;
  if not Found then
  begin
    ErrMsg := Prefix + ': "message" is missing';
    Exit(False);
  end;

  Found := False;
  for I := 0 to Obj.Count - 1 do
  begin
    if Obj.Names[I] = 'severity' then
    begin
      Found := True;
      if Obj.Items[I].JSONType <> jtString then
      begin
        ErrMsg := Prefix + ': "severity": expected a string';
        Exit(False);
      end;
      SevVal := Obj.Items[I].AsString;
      Break;
    end;
  end;
  if not Found then
  begin
    ErrMsg := Prefix + ': "severity" is missing';
    Exit(False);
  end;
  if (SevVal = 'ERROR') or (SevVal = 'HIGH') or (SevVal = 'CRITICAL') then
    Sev := svError
  else if (SevVal = 'WARNING') or (SevVal = 'MEDIUM') then
    Sev := svWarning
  else if (SevVal = 'INFO') or (SevVal = 'LOW') then
  begin
    // svInfo（未決 #6 の決定）は M2 で入る。それまで svWarning に寄せると、
    // ルール作者の意図より重く報告して --fail-on=warning の CI を落としうるので受け付けない。
    ErrMsg := Prefix + ': "severity": "' + SevVal + '" is not supported yet (svInfo is planned for M2)';
    Exit(False);
  end
  else
  begin
    ErrMsg := Prefix + ': "severity": unknown value "' + SevVal + '"';
    Exit(False);
  end;

  for I := 0 to Obj.Count - 1 do
  begin
    if Obj.Names[I] = 'metadata' then
    begin
      if Obj.Items[I].JSONType <> jtObject then
      begin
        ErrMsg := Prefix + ': "metadata": expected an object';
        Exit(False);
      end;
      Break;
    end;
  end;

  LexOpts := DefaultPatLexOptions;
  GoDeeper := True;
  for I := 0 to Obj.Count - 1 do
  begin
    if Obj.Names[I] = 'options' then
    begin
      if Obj.Items[I].JSONType <> jtObject then
      begin
        ErrMsg := Prefix + ': "options": expected an object';
        Exit(False);
      end;
      OptObj := TJSONObject(Obj.Items[I]);
      for J := 0 to OptObj.Count - 1 do
      begin
        Key := OptObj.Names[J];
        if Key = 'pascal_hex_dollar' then
        begin
          if OptObj.Items[J].JSONType <> jtBoolean then
          begin
            ErrMsg := Prefix + ': "options": "pascal_hex_dollar": expected true or false';
            Exit(False);
          end;
          LexOpts.PascalHexDollar := OptObj.Items[J].AsBoolean;
        end
        else if Key = 'go_deeper_stmt' then
        begin
          if OptObj.Items[J].JSONType <> jtBoolean then
          begin
            ErrMsg := Prefix + ': "options": "go_deeper_stmt": expected true or false';
            Exit(False);
          end;
          GoDeeper := OptObj.Items[J].AsBoolean;
        end
        else
        begin
          ErrMsg := Prefix + ': "options": unknown option "' + Key + '"';
          Exit(False);
        end;
      end;
      Break;
    end;
  end;

  // ルールの直下に書ける式は `pattern` / `patterns` / `pattern-either` のどれか 1 つ。
  // 否定と inside は opengrep でも `patterns` の中にしか書けない。
  FormulaCount := 0;
  FormulaIdx := -1;
  for I := 0 to Obj.Count - 1 do
  begin
    Key := Obj.Names[I];
    if (Key = 'pattern-not') or (Key = 'pattern-inside') or (Key = 'pattern-not-inside') then
    begin
      ErrMsg := Prefix + ': "' + Key + '" is only allowed inside "patterns"';
      Exit(False);
    end;
    if (Key = 'pattern') or (Key = 'patterns') or (Key = 'pattern-either') then
    begin
      Inc(FormulaCount);
      FormulaIdx := I;
    end;
  end;
  if FormulaCount = 0 then
  begin
    ErrMsg := Prefix + ': "pattern", "patterns" or "pattern-either" is missing';
    Exit(False);
  end;
  if FormulaCount > 1 then
  begin
    ErrMsg := Prefix + ': only one of "pattern", "patterns" and "pattern-either" is allowed';
    Exit(False);
  end;
  KindForKey(Obj.Names[FormulaIdx], RootKind);
  if not ParseFormula(Obj.Items[FormulaIdx], RootKind, '"' + Obj.Names[FormulaIdx] + '"',
    LexOpts, Notices, Prefix, Form, ErrMsg) then
  begin
    ErrMsg := Prefix + ': ' + ErrMsg;
    Exit(False);
  end;

  // message がパターンで束縛されないメタ変数を参照していたら警告する。補間されずに
  // `$Y` のまま出るのでたぶん書き間違いだが、エラーにはしない。pattern-either では
  // 片方の枝でだけ束縛される名前が正当にありうるため。
  BoundVars := nil;
  BoundEllipses := nil;
  CollectBoundNames(Form, BoundVars, BoundEllipses);
  Refs := FindMessageMetaVars(MsgVal);
  Warned := nil;
  for W := 0 to High(Refs) do
  begin
    if Refs[W].IsEllipsis then
      RefBound := InArray(Refs[W].Name, BoundEllipses)
    else
      // `$_` は照合器が束縛しない（PatMatcher.MatchNode）。
      RefBound := (Refs[W].Name <> '_') and InArray(Refs[W].Name, BoundVars);
    RefText := Copy(MsgVal, Refs[W].StartPos, Refs[W].Len);
    if (not RefBound) and (not InArray(RefText, Warned)) then
    begin
      SetLength(Warned, Length(Warned) + 1);
      Warned[High(Warned)] := RefText;
      if Notices <> nil then
        Notices.Add(Prefix + ': warning: "message" refers to ' + RefText + ', which the pattern does not bind');
    end;
  end;

  Rule := TDeclRule.Create;
  Rule.Id := RuleId;
  Rule.Message := MsgVal;
  Rule.Severity := Sev;
  Rule.Formula := Form;
  Rule.LexOptions := LexOpts;
  Rule.GoDeeperStmt := GoDeeper;
  Rule.SourceFile := SrcName;

  Result := True;
end;


function LoadRulesFromText(const Text, SourceName: string; Rules: TDeclRuleList;
  Notices: TStrings; out ErrorMessage: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  RulesArr: TJSONArray;
  I, J: Integer;
  Key: string;
  HasRules: Boolean;
  TempRules: array of TDeclRule;
  Rule: TDeclRule;
  RuleErr: string;
  Skipped: Boolean;
  Dup: Boolean;
begin
  ErrorMessage := '';
  Data := nil;
  try
    try
      Data := GetJSON(Text);
    except
      on E: Exception do
      begin
        ErrorMessage := SourceName + ': invalid JSON: ' + E.Message;
        Exit(False);
      end;
    end;

    if (Data = nil) or (Data.JSONType <> jtObject) then
    begin
      ErrorMessage := SourceName + ': the top level must be a JSON object';
      Exit(False);
    end;

    Root := TJSONObject(Data);
    HasRules := False;
    for I := 0 to Root.Count - 1 do
    begin
      Key := Root.Names[I];
      if Key = 'rules' then
      begin
        HasRules := True;
        if Root.Items[I].JSONType <> jtArray then
        begin
          ErrorMessage := SourceName + ': "rules": expected an array';
          Exit(False);
        end;
        RulesArr := TJSONArray(Root.Items[I]);
      end
      else
      begin
        ErrorMessage := SourceName + ': unknown top level key "' + Key + '"';
        Exit(False);
      end;
    end;

    if not HasRules then
    begin
      ErrorMessage := SourceName + ': "rules" is missing';
      Exit(False);
    end;

    SetLength(TempRules, 0);
    for I := 0 to RulesArr.Count - 1 do
    begin
      if RulesArr.Items[I].JSONType <> jtObject then
      begin
        ErrorMessage := SourceName + ': rules[' + IntToStr(I) + ']: expected an object';
        for J := 0 to High(TempRules) do
          TempRules[J].Free;
        Exit(False);
      end;

      if not LoadOneRule(TJSONObject(RulesArr.Items[I]), SourceName, I,
        Rule, RuleErr, Notices, Skipped) then
      begin
        // 他言語のルールは通知を積んだうえで飛ばすだけで、ファイルの読み込みは続ける。
        if Skipped then
          Continue;
        ErrorMessage := RuleErr;
        for J := 0 to High(TempRules) do
          TempRules[J].Free;
        Exit(False);
      end;

      // 既に読み込んだ別ファイルのルールとも、このファイルの中とも重複させない。
      Dup := Rules.FindById(Rule.Id) <> nil;
      for J := 0 to High(TempRules) do
        if TempRules[J].Id = Rule.Id then
          Dup := True;
      if Dup then
      begin
        ErrorMessage := SourceName + ': rules[' + IntToStr(I) +
          '] (id "' + Rule.Id + '"): "id": duplicate rule id "' + Rule.Id + '"';
        Rule.Free;
        for J := 0 to High(TempRules) do
          TempRules[J].Free;
        Exit(False);
      end;

      SetLength(TempRules, Length(TempRules) + 1);
      TempRules[Length(TempRules) - 1] := Rule;
    end;

    for I := 0 to High(TempRules) do
      Rules.Add(TempRules[I]);

    Result := True;
  finally
    if Data <> nil then
      Data.Free;
  end;
end;


function DumpRules(Rules: TDeclRuleList): string;
var
  I: Integer;
  R: TDeclRule;
begin
  if Rules.Count = 0 then
  begin
    Result := 'no rules' + #10;
    Exit;
  end;

  Result := '';
  for I := 0 to Rules.Count - 1 do
  begin
    R := Rules[I];
    Result := Result + 'rule ' + R.Id + #10;
    Result := Result + '  file: ' + R.SourceFile + #10;
    if R.Severity = svError then
      Result := Result + '  severity: error' + #10
    else
      Result := Result + '  severity: warning' + #10;
    Result := Result + '  message: ' + R.Message + #10;
    if R.LexOptions.PascalHexDollar then
      Result := Result + '  options: pascal_hex_dollar=true'
    else
      Result := Result + '  options: pascal_hex_dollar=false';
    if R.GoDeeperStmt then
      Result := Result + ' go_deeper_stmt=true' + #10
    else
      Result := Result + ' go_deeper_stmt=false' + #10;
    Result := Result + DumpFormula(R.Formula, 2);
  end;
end;

end.
