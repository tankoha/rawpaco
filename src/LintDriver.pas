unit LintDriver;

{$mode objfpc}{$H+}

interface

function RunLint(const FileNames: array of string): Integer;

implementation

uses
  SysUtils, Classes, TSBindings, Diagnostics, ASTWalker, AllRules;

function ReadFileAsString(const FileName: string): AnsiString;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function RunLint(const FileNames: array of string): Integer;
var
  Parser: TSParser;
  Tree: PTSTree;
  Root: TSNode;
  Source: AnsiString;
  Ctx: TLintContext;
  Diag: TDiagnostic;
  FileName: string;
  HadDiagnostics: Boolean;
  HadReadError: Boolean;
begin
  HadDiagnostics := False;
  HadReadError := False;

  Parser := ts_parser_new;
  try
    if not ts_parser_set_language(Parser, tree_sitter_pascal) then
    begin
      WriteLn(StdErr, 'error: tree-sitter-pascal language failed to load');
      Exit(1);
    end;

    for FileName in FileNames do
    begin
      try
        Source := ReadFileAsString(FileName);
      except
        on E: Exception do
        begin
          WriteLn(StdErr, 'error: cannot read ', FileName, ': ', E.Message);
          HadReadError := True;
          Continue;
        end;
      end;

      Tree := ts_parser_parse_string(Parser, nil, PAnsiChar(Source), Length(Source));
      try
        Root := ts_tree_root_node(Tree);
        Ctx := TLintContext.Create(FileName, Source);
        try
          WalkTree(Root, Ctx);
          for Diag in Ctx.Diagnostics do
          begin
            WriteLn(FormatDiagnosticText(Diag));
            HadDiagnostics := True;
          end;
        finally
          Ctx.Free;
        end;
      finally
        ts_tree_delete(Tree);
      end;
    end;
  finally
    ts_parser_delete(Parser);
  end;

  if HadDiagnostics or HadReadError then
    Result := 1
  else
    Result := 0;
end;

end.
