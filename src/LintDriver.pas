unit LintDriver;

{$mode objfpc}{$H+}

interface

uses
  Diagnostics;

// OutFormatという名前にしているのは、単にFormatにするとSysUtils.Formatを
// 隠してしまい、本関数内でFormat()による文字列整形が必要になった際に
// 気付きにくい形で壊れるため(パラメータ名がグローバル関数名と衝突する
// FPCの通常のスコープ規則)。
// MinFailSeverity: 設計書4.1.3節の`--fail-on`しきい値。既定はsvError
// (rawpaco.lprのCLIパース側が既定値'error'を解決してここに渡す。このユニット
// 自身はCLIオプションの存在を知らない、というRuleRegistry.SetRuleFilter等
// 既存の役割分担を踏襲)。
function RunLint(const FileNames: array of string; OutFormat: TOutputFormat;
  MinFailSeverity: TSeverity): Integer;

implementation

uses
  SysUtils, Classes, TSBindings, ASTWalker, AllRules;

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

function RunLint(const FileNames: array of string; OutFormat: TOutputFormat;
  MinFailSeverity: TSeverity): Integer;
var
  Parser: TSParser;
  Tree: PTSTree;
  Root: TSNode;
  Source: AnsiString;
  Ctx: TLintContext;
  Diag: TDiagnostic;
  FileName: string;
  HadReadError: Boolean;
  AllDiags: TDiagnosticList;
  Lines: TStringArray;
begin
  HadReadError := False;
  // json形式は診断結果全体を1個の配列にまとめて出す必要がある(設計書4節)ため、
  // text/githubも含めて全ファイル分をここに集約してから最後にまとめて出力する
  // 方式に統一する(ファイルごとに逐次出力する旧実装のような形式ごとの分岐を
  // 増やさずに済む)。抑制コメント(rawpaco:ignore)によるフィルタもここで通す。
  AllDiags := TDiagnosticList.Create;
  try
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
            Lines := SplitSourceLines(Source);
            for Diag in Ctx.Diagnostics do
              if not IsDiagnosticSuppressed(Lines, Diag) then
                AllDiags.Add(Diag);
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

    case OutFormat of
      ofText:
        for Diag in AllDiags do
          WriteLn(FormatDiagnosticText(Diag));
      ofGithub:
        for Diag in AllDiags do
          WriteLn(FormatDiagnosticGithub(Diag));
      ofJson:
        WriteLn(FormatDiagnosticsJson(AllDiags));
    end;

    // 設計書4.1.3節: --fail-onはどの診断が出力されるかには一切影響せず、
    // 集約済みのAllDiags(抑制済み)に対してしきい値以上のものが1件でも
    // あるかどうかだけを見る。
    if HasDiagnosticAtOrAbove(AllDiags, MinFailSeverity) or HadReadError then
      Result := 1
    else
      Result := 0;
  finally
    AllDiags.Free;
  end;
end;

end.
