program rawpaco;

{$mode objfpc}{$H+}

uses
  SysUtils, TSBindings, LintDriver;

const
  VersionString = '0.0.1-dev';

var
  Parser: TSParser;
  Tree: PTSTree;
  Root: TSNode;
  Source: AnsiString;
  Files: array of string;
  I: Integer;
begin
  WriteLn('rawpaco ', VersionString, ' - FPC/Lazarus Pascal lint tool (tree-sitter-pascal based)');

  if ParamCount = 0 then
  begin
    // 引数なし: 既存の自己チェック(tree-sitter-pascalが正しくリンク・
    // 動作することの確認)。CIの`./src/rawpaco`(Linux)/`./src/rawpaco.exe`
    // (Windows)という引数なし呼び出しが無改修で動き続けるよう、この
    // ブロックの内容は変更しない。
    WriteLn('status: bootstrap, no lint rules implemented yet');
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
    SetLength(Files, ParamCount);
    for I := 1 to ParamCount do
      Files[I - 1] := ParamStr(I);
    Halt(LintDriver.RunLint(Files));
  end;
end.
