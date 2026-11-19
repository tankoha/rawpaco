program rawpaco;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, TSBindings, LintDriver, RawpacoConfig, RuleRegistry, Diagnostics,
  PatLexer, PatCompiler, PatMatcher, RuleFile, DeclRule;

const
  VersionString = '0.0.1-dev';

// ","区切りの文字列をトリムしつつ配列にする。空要素(末尾カンマ等)は捨てる。
// 全体が空(例: "--only=")ならエラーにする側の判断は呼び出し元で行う
// (このユニット内で完結させると「空リスト=フィルタなし」との区別が
// 呼び出し元から見えなくなるため)。
function SplitCommaList(const S: string): TStringArray;
var
  Parts: TStringList;
  I: Integer;
  Item: string;
  Ids: TStringArray;
begin
  SetLength(Ids, 0);
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := ',';
    Parts.DelimitedText := S;
    for I := 0 to Parts.Count - 1 do
    begin
      Item := Trim(Parts[I]);
      if Item <> '' then
      begin
        SetLength(Ids, Length(Ids) + 1);
        Ids[High(Ids)] := Item;
      end;
    end;
  finally
    Parts.Free;
  end;
  Result := Ids;
end;

// ゴールデンテスト（設計書 7.1）用：パターン IR を標準出力にダンプする。
// tree-sitter-pascal の更新でパターンツリーの形状が変わった場合、
// diff として検出できる（CLAUDE.md ルール 2）。
// 開発者向けオプションであり、通常使用を想定していない。
function RunDumpPattern(const Path: string): Integer;
var
  L: TStringList;
  PatText: string;
  R: TPatCompileResult;
begin
  if not FileExists(Path) then
  begin
    WriteLn(StdErr, 'error: pattern file not found: ', Path);
    Result := 2;
    Exit;
  end;

  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    PatText := L.Text;
  finally
    L.Free;
  end;

  if (Length(PatText) >= 2) and (PatText[Length(PatText) - 1] = #13) and (PatText[Length(PatText)] = #10) then
    SetLength(PatText, Length(PatText) - 2)
  else if (Length(PatText) >= 1) and (PatText[Length(PatText)] = #10) then
    SetLength(PatText, Length(PatText) - 1);

  R := CompilePattern(PatText, DefaultPatLexOptions);
  try
    Write(DumpPattern(R));
  finally
    R.Root.Free;
  end;

  if R.Ok then
    Result := 0
  else
    Result := 2;
end;

// 開発者向けオプション: ルールファイル（JSON）を読み込み、読めたルールとコンパイル後の
// パターンを標準出力に表示する。ルールローダのゴールデンテスト（tests/decl/load）用。
// 読み込みエラーは --rules と同じく終了コード 2 にする。
function RunDumpRules(const Path: string): Integer;
var
  Rules: TDeclRuleList;
  Notices: TStringList;
  ErrorMessage: string;
  I: Integer;
begin
  Rules := TDeclRuleList.Create;
  Notices := TStringList.Create;
  try
    if not LoadRulesFromFile(Path, Rules, Notices, ErrorMessage) then
    begin
      WriteLn('error: ', ErrorMessage);
      Result := 2;
      Exit;
    end;
    for I := 0 to Notices.Count - 1 do
      WriteLn('notice: ', Notices[I]);
    Write(DumpRules(Rules));
    Result := 0;
  finally
    Notices.Free;
    Rules.Free;
  end;
end;

// 開発者向けオプション: パターンがソース内のどこにマッチし、メタ変数に何が
// バインドされたかを標準出力に表示する。マッチャのゴールデンテスト
// (tests/decl/match) 用であり、JSON ルールローダー完成までの暫定手段。
function RunMatchPattern(const PatPath: string; const Files: array of string): Integer;
var
  PatText: string;
  R: TPatCompileResult;
  Parser: TSParser;
  F: string;
  Source: string;
  Tree: PTSTree;
  Matches: TPatMatchArray;
  MatchedText: string;
  Prefix: string;
  i, j, k: Integer;

  function FirstLine(const S: string): string;
  var
    n: Integer;
  begin
    for n := 1 to Length(S) do
    begin
      if (S[n] = #13) or (S[n] = #10) then
      begin
        Result := Copy(S, 1, n - 1);
        Exit;
      end;
    end;
    Result := S;
  end;

begin
  Result := 0;

  if not FileExists(PatPath) then
  begin
    WriteLn(StdErr, 'error: pattern file not found: ', PatPath);
    Result := 2;
    Exit;
  end;

  PatText := ReadFileAsString(PatPath);
  if (Length(PatText) >= 2) and (PatText[Length(PatText) - 1] = #13) and (PatText[Length(PatText)] = #10) then
    Delete(PatText, Length(PatText) - 1, 2)
  else if (Length(PatText) >= 1) and (PatText[Length(PatText)] = #10) then
    Delete(PatText, Length(PatText), 1);

  R := CompilePattern(PatText, DefaultPatLexOptions);
  if not R.Ok then
  begin
    WriteLn(StdErr, 'error: ', R.ErrorMessage);
    Result := 2;
    Exit;
  end;

  try
    Parser := ts_parser_new;
    ts_parser_set_language(Parser, tree_sitter_pascal);
    try
      for i := 0 to High(Files) do
      begin
        F := Files[i];
        if not FileExists(F) then
        begin
          WriteLn(StdErr, 'error: file not found: ', F);
          Result := 2;
          Continue;
        end;

        Source := ReadFileAsString(F);
        Tree := ts_parser_parse_string(Parser, nil, PAnsiChar(Source), Length(Source));
        try
          Matches := FindMatches(R.Root, ts_tree_root_node(Tree), Source);
          for j := 0 to High(Matches) do
          begin
            MatchedText := Copy(Source, Matches[j].StartByte + 1, Matches[j].EndByte - Matches[j].StartByte);
            WriteLn(Format('%s:%d:%d-%d:%d: %s',
              [F, Matches[j].StartPoint.row + 1, Matches[j].StartPoint.column + 1,
               Matches[j].EndPoint.row + 1, Matches[j].EndPoint.column + 1,
               FirstLine(MatchedText)]));
            for k := 0 to High(Matches[j].Bindings) do
            begin
              if Matches[j].Bindings[k].IsRange then
                Prefix := '  $...'
              else
                Prefix := '  $';
              WriteLn(Prefix + Matches[j].Bindings[k].Name + ' = ' + FirstLine(BindingText(Matches[j].Bindings[k], Source)));
            end;
          end;
        finally
          ts_tree_delete(Tree);
        end;
      end;
    finally
      ts_parser_delete(Parser);
    end;
  finally
    R.Root.Free;
  end;
end;

var
  Parser: TSParser;
  Tree: PTSTree;
  Root: TSNode;
  Source: AnsiString;
  Files: array of string;
  I: Integer;
  Arg, ConfigPath, ConfigError, FilterError, FormatError, FormatStr,
    FailOnError, FailOnStr, MatchPath: string;
  OnlyIds, ExcludeIds, RulePaths: TStringArray;
  OutFormat: TOutputFormat;
  FailOnLevel: TSeverity;
  DeclRules: TDeclRuleList;
  RuleNotices: TStringList;
  RulesError: string;
  LintResult: Integer;
begin
  WriteLn('rawpaco ', VersionString, ' - FPC/Lazarus Pascal lint tool (tree-sitter-pascal based)');

  if ParamCount = 0 then
  begin
    // 引数なし: 既存の自己チェック(tree-sitter-pascalが正しくリンク・
    // 動作することの確認)。CIの`./src/rawpaco`(Linux)/`./src/rawpaco.exe`
    // (Windows)という引数なし呼び出しが無改修で動き続けるよう、この
    // ブロックの制御フロー・終了コードは変更しない(WriteLnの文言のみ
    // 実態に合わせて更新可能)。
    WriteLn('status: bootstrap self-check (lint rules are implemented; run with file arguments to lint)');
    Parser := ts_parser_new;
    try
      if not ts_parser_set_language(Parser, tree_sitter_pascal) then
      begin
        WriteLn(StdErr, 'error: tree-sitter-pascal language failed to load');
        Halt(1);
      end;
      Source := 'program p; begin end.';
      Tree := ts_parser_parse_string(Parser, nil, PAnsiChar(Source), Length(Source));
      try
        Root := ts_tree_root_node(Tree);
        WriteLn('self-check parse: ', ts_node_string(Root));
      finally
        ts_tree_delete(Tree);
      end;
    finally
      ts_parser_delete(Parser);
    end;
  end
  else
  begin
    // オプションは `--` 始まり、それ以外は解析対象ファイルとして扱う。
    // 未知のオプションを黙ってファイル名として扱うと「存在しないファイル」
    // エラーになって分かりにくいので、明示的に弾く。
    ConfigPath := '';
    FormatStr := 'text';
    // 設計書4.1.3/4.1.7節: 既定は寛容(error階層のみが既定でビルドを落とす)。
    // 従来の「診断1件でも失敗」を再現する激辛モードは--fail-on=warningを
    // 明示指定する(rawpaco自身のselflintがこれを使う。Makefile参照)。
    FailOnStr := 'error';
    SetLength(OnlyIds, 0);
    SetLength(ExcludeIds, 0);
    SetLength(Files, 0);
    SetLength(RulePaths, 0);
    MatchPath := '';
    for I := 1 to ParamCount do
    begin
      Arg := ParamStr(I);
      if Copy(Arg, 1, 16) = '--match-pattern=' then
        MatchPath := Copy(Arg, 17, MaxInt)
      else if Copy(Arg, 1, 8) = '--rules=' then
      begin
        // 繰り返し指定できる（設計書 OPENGREP_RULE_ENGINE_DESIGN 4.7）。
        if Length(Arg) = 8 then
        begin
          WriteLn(StdErr, 'error: --rules= requires a rule file or directory');
          Halt(2);
        end;
        SetLength(RulePaths, Length(RulePaths) + 1);
        RulePaths[High(RulePaths)] := Copy(Arg, 9, MaxInt);
      end
      else if Copy(Arg, 1, 13) = '--dump-rules=' then
        Halt(RunDumpRules(Copy(Arg, 14, MaxInt)))
      else if Copy(Arg, 1, 15) = '--dump-pattern=' then
        Halt(RunDumpPattern(Copy(Arg, 16, MaxInt)))
      else if Copy(Arg, 1, 9) = '--config=' then
        ConfigPath := Copy(Arg, 10, Length(Arg))
      else if Copy(Arg, 1, 9) = '--format=' then
        FormatStr := Copy(Arg, 10, Length(Arg))
      else if Copy(Arg, 1, 10) = '--fail-on=' then
        FailOnStr := Copy(Arg, 11, Length(Arg))
      else if Copy(Arg, 1, 7) = '--only=' then
      begin
        OnlyIds := SplitCommaList(Copy(Arg, 8, Length(Arg)));
        // 値を見た直後にその場でチェックする。ループ完了後に
        // 「OnlyIds/ExcludeIds両方が空か」だけを見ていた旧実装は、
        // 例えば `--only= --exclude=RAWPACO-X` のように片方だけが
        // 空だともう片方の非空でこのチェックがすり抜けてしまうバグが
        // あった(Fable5のレビューで発見)。フラグごとに独立して検証する。
        if Length(OnlyIds) = 0 then
        begin
          WriteLn(StdErr, 'error: ', Arg, ' requires a comma-separated list of rule ids');
          Halt(2);
        end;
      end
      else if Copy(Arg, 1, 10) = '--exclude=' then
      begin
        ExcludeIds := SplitCommaList(Copy(Arg, 11, Length(Arg)));
        if Length(ExcludeIds) = 0 then
        begin
          WriteLn(StdErr, 'error: ', Arg, ' requires a comma-separated list of rule ids');
          Halt(2);
        end;
      end
      else if Copy(Arg, 1, 2) = '--' then
      begin
        WriteLn(StdErr, 'error: unknown option ', Arg);
        WriteLn(StdErr, 'usage: rawpaco [--config=<path>] [--format=text|github|json] [--fail-on=error|warning|info] [--only=<id>[,<id>...] | --exclude=<id>[,<id>...]] [--rules=<file.json|dir> ...] <file.pas> ...');
        Halt(2);
      end
      else
      begin
        SetLength(Files, Length(Files) + 1);
        Files[High(Files)] := Arg;
      end;
    end;

    // 開発者向けの --match-pattern は lint 本体の設定やルールの絞り込みと無関係なので、
    // それらの検証より前に分岐する。
    if MatchPath <> '' then
      Halt(RunMatchPattern(MatchPath, Files));

    if not InitConfig(ConfigPath, ConfigError) then
    begin
      WriteLn(StdErr, 'error: ', ConfigError);
      Halt(2);
    end;

    if not ParseOutputFormat(FormatStr, OutFormat, FormatError) then
    begin
      WriteLn(StdErr, 'error: ', FormatError);
      Halt(2);
    end;

    if not ParseFailOnLevel(FailOnStr, FailOnLevel, FailOnError) then
    begin
      WriteLn(StdErr, 'error: ', FailOnError);
      Halt(2);
    end;

    // --onlyと--excludeの同時指定は「両方の集合をどう組み合わせるか」が
    // 自明ではない(積？和の補集合？)ため、あいまいさを残さず明示的に
    // エラーにする(rawpaco.jsonの未知キー同様、寛容にしない方針)。
    if (Length(OnlyIds) > 0) and (Length(ExcludeIds) > 0) then
    begin
      WriteLn(StdErr, 'error: --only and --exclude cannot be used together');
      Halt(2);
    end;

    // 宣言的ルールは --only / --exclude の ID 検査より前に登録する。SetRuleFilter は
    // 登録済みのルールの ID だけを既知とみなすため（設計書 OPENGREP_RULE_ENGINE_DESIGN 4.7）。
    // DeclRules はアダプタが参照するので、lint が終わるまで解放しない。
    DeclRules := TDeclRuleList.Create;
    RuleNotices := TStringList.Create;
    try
      if Length(RulePaths) > 0 then
      begin
        if not LoadAndRegisterDeclRules(RulePaths, DeclRules, RuleNotices, RulesError) then
        begin
          WriteLn(StdErr, 'error: ', RulesError);
          Halt(2);
        end;
        for I := 0 to RuleNotices.Count - 1 do
          WriteLn(StdErr, 'notice: ', RuleNotices[I]);
      end;

      if not RuleRegistry.SetRuleFilter(OnlyIds, ExcludeIds, FilterError) then
      begin
        WriteLn(StdErr, 'error: ', FilterError);
        Halt(2);
      end;

      if Length(Files) = 0 then
      begin
        WriteLn(StdErr, 'error: no input files');
        Halt(2);
      end;

      LintResult := LintDriver.RunLint(Files, OutFormat, FailOnLevel);
    finally
      RuleNotices.Free;
      DeclRules.Free;
    end;
    Halt(LintResult);
  end;
end.
