unit Diagnostics;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Generics.Collections, TSBindings;

type
  TSeverity = (svWarning); // 将来svErrorを追加する余地は残すが、CLAUDE.mdルール5
                           // (誤検知回避優先)の方針上、「問答無用でCIを落とす」と
                           // 断定できるルールがまだ無いため現時点ではsvWarning統一

  TDiagnostic = record
    RuleId: string;
    Message: string;
    FileName: string;
    Line, Column: LongWord; // 1-origin(人間向け表示に合わせる。
                             // ts_node_start_pointは0-originなので+1する)
    Severity: TSeverity;
  end;

  TDiagnosticList = specialize TList<TDiagnostic>;

  TLintContext = class
  private
    FFileName: string;
    FSource: AnsiString;
    FDiagnostics: TDiagnosticList;
  public
    constructor Create(const AFileName: string; const ASource: AnsiString);
    destructor Destroy; override;
    procedure Report(const ARuleId, AMessage: string; const Node: TSNode);
    function GetNodeText(const Node: TSNode): AnsiString;
    property FileName: string read FFileName;
    property Diagnostics: TDiagnosticList read FDiagnostics;
  end;

function FormatDiagnosticText(const Diag: TDiagnostic): string;

implementation

constructor TLintContext.Create(const AFileName: string; const ASource: AnsiString);
begin
  inherited Create;
  FFileName := AFileName;
  FSource := ASource;
  FDiagnostics := TDiagnosticList.Create;
end;

destructor TLintContext.Destroy;
begin
  FDiagnostics.Free;
  inherited Destroy;
end;

procedure TLintContext.Report(const ARuleId, AMessage: string; const Node: TSNode);
var
  Diag: TDiagnostic;
  Point: TSPoint;
begin
  Point := ts_node_start_point(Node);
  Diag.RuleId := ARuleId;
  Diag.Message := AMessage;
  Diag.FileName := FFileName;
  Diag.Line := Point.row + 1;
  Diag.Column := Point.column + 1;
  Diag.Severity := svWarning;
  FDiagnostics.Add(Diag);
end;

function TLintContext.GetNodeText(const Node: TSNode): AnsiString;
var
  StartByte, EndByte: LongWord;
begin
  // ts_node_start_byte/end_byteは0-originのバイトオフセット(api.h)。
  // FPCのCopyは1-originなので+1する(Reportの行番号+1と同じ理由)。
  // RAWPACO-DEFENSE-001は木の構造しか見なかったため、これまでTLintContext
  // はソース本文を一切保持していなかった。RAWPACO-SEC-001/002で識別子名・
  // 文字列リテラルの実テキストが初めて必要になったため追加する。
  StartByte := ts_node_start_byte(Node);
  EndByte := ts_node_end_byte(Node);
  Result := Copy(FSource, StartByte + 1, EndByte - StartByte);
end;

function FormatDiagnosticText(const Diag: TDiagnostic): string;
begin
  Result := Format('%s:%d:%d: warning: %s [%s]',
    [Diag.FileName, Diag.Line, Diag.Column, Diag.Message, Diag.RuleId]);
end;

end.
