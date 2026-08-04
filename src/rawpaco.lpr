program rawpaco;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, TSBindings, LintDriver, RawpacoConfig, RuleRegistry;

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

var
  Parser: TSParser;
  Tree: PTSTree;
  Root: TSNode;
  Source: AnsiString;
  Files: array of string;
  I: Integer;
  Arg, ConfigPath, ConfigError, FilterError: string;
  OnlyIds, ExcludeIds: TStringArray;
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
    SetLength(OnlyIds, 0);
    SetLength(ExcludeIds, 0);
    SetLength(Files, 0);
    for I := 1 to ParamCount do
    begin
      Arg := ParamStr(I);
      if Copy(Arg, 1, 9) = '--config=' then
        ConfigPath := Copy(Arg, 10, Length(Arg))
      else if Copy(Arg, 1, 7) = '--only=' then
        OnlyIds := SplitCommaList(Copy(Arg, 8, Length(Arg)))
      else if Copy(Arg, 1, 10) = '--exclude=' then
        ExcludeIds := SplitCommaList(Copy(Arg, 11, Length(Arg)))
      else if Copy(Arg, 1, 2) = '--' then
      begin
        WriteLn(StdErr, 'error: unknown option ', Arg);
        WriteLn(StdErr, 'usage: rawpaco [--config=<path>] [--only=<id>[,<id>...] | --exclude=<id>[,<id>...]] <file.pas> ...');
        Halt(2);
      end
      else
      begin
        SetLength(Files, Length(Files) + 1);
        Files[High(Files)] := Arg;
      end;
    end;

    if not InitConfig(ConfigPath, ConfigError) then
    begin
      WriteLn(StdErr, 'error: ', ConfigError);
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
    if (Length(OnlyIds) = 0) and (Length(ExcludeIds) = 0) then
    begin
      // "--only=" や "--exclude=" だけ渡して中身が空、というのは
      // 「フィルタなし」と区別が付かず事故のもとなので、フラグ自体が
      // 一度も現れていない場合とは別に、空リストで渡された場合はここで
      // 検出してエラーにする。
      for I := 1 to ParamCount do
        if (ParamStr(I) = '--only=') or (ParamStr(I) = '--exclude=') then
        begin
          WriteLn(StdErr, 'error: ', ParamStr(I), ' requires a comma-separated list of rule ids');
          Halt(2);
        end;
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

    Halt(LintDriver.RunLint(Files));
  end;
end.
