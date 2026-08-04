unit Diagnostics;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Generics.Collections, TSBindings;

type
  TSeverity = (svWarning); // 将来svErrorを追加する余地は残すが、CLAUDE.mdルール5
                           // (誤検知回避優先)の方針上、「問答無用でCIを落とす」と
                           // 断定できるルールがまだ無いため現時点ではsvWarning統一

  // 設計書4節。text=人間向け(既定)、github=GitHub Actions workflow command
  // (PRのdiffにインライン注釈を付ける)、json=他ツール連携向け機械可読形式。
  TOutputFormat = (ofText, ofGithub, ofJson);

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

// CLI引数の文字列("text"/"github"/"json")を検証しつつ変換する。未知の値は
// Falseを返しErrorMsgに理由を入れる(rawpaco.jsonの未知キー等と同じ方針、
// CLAUDE.mdルール5: タイプミスを黙って無視しない)。
function ParseOutputFormat(const S: string; out AFormat: TOutputFormat;
  out ErrorMsg: string): Boolean;

function FormatDiagnosticText(const Diag: TDiagnostic): string;
function FormatDiagnosticGithub(const Diag: TDiagnostic): string;
function FormatDiagnosticsJson(const Diags: TDiagnosticList): string;

// ソースを行単位に分割する。tree-sitterのTSPoint.row(TDiagnostic.Lineの元)は
// lexer.cのadvance()が'\n'の出現だけで数えており'\r'単体は改行扱いしない
// (CLAUDE.mdルール1: 照合先はvendor配下の実装そのもの)。TStringList.Text
// のような「CR/LF/CRLFいずれも改行」という汎用パーサだと、稀にtree-sitter
// との行番号がずれるため、同じ基準(\nのみ)で自前分割する。
function SplitSourceLines(const Source: AnsiString): TStringArray;

// 抑制コメント(`// rawpaco:ignore <RuleId>`)による抑制対象かどうかを判定する。
// 設計書4節: 診断対象の行、またはその直前の行のいずれかに当該RuleIdの
// 抑制コメントがあれば抑制する。
function IsDiagnosticSuppressed(const Lines: TStringArray;
  const Diag: TDiagnostic): Boolean;

implementation

uses
  fpjson;

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

function ParseOutputFormat(const S: string; out AFormat: TOutputFormat;
  out ErrorMsg: string): Boolean;
begin
  ErrorMsg := '';
  Result := True;
  if S = 'text' then
    AFormat := ofText
  else if S = 'github' then
    AFormat := ofGithub
  else if S = 'json' then
    AFormat := ofJson
  else
  begin
    ErrorMsg := Format(
      'unknown --format value: %s (expected text, github, or json)', [S]);
    Result := False;
  end;
end;

function FormatDiagnosticText(const Diag: TDiagnostic): string;
begin
  Result := Format('%s:%d:%d: warning: %s [%s]',
    [Diag.FileName, Diag.Line, Diag.Column, Diag.Message, Diag.RuleId]);
end;

// GitHub Actions workflow commandのエスケープ規則(actions/toolkitの
// command.tsに準拠)。プロパティ値(file=/line=/col=)は`:`と`,`もエスケープ
// する必要がある(値の区切り文字と衝突するため)が、`::`以降のメッセージ本文は
// その2文字のエスケープは不要。
function EscapeGithubData(const S: string): string;
begin
  Result := StringReplace(S, '%', '%25', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '%0D', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '%0A', [rfReplaceAll]);
end;

function EscapeGithubProperty(const S: string): string;
begin
  Result := EscapeGithubData(S);
  Result := StringReplace(Result, ':', '%3A', [rfReplaceAll]);
  Result := StringReplace(Result, ',', '%2C', [rfReplaceAll]);
end;

function FormatDiagnosticGithub(const Diag: TDiagnostic): string;
begin
  Result := Format('::warning file=%s,line=%d,col=%d::[%s] %s',
    [EscapeGithubProperty(Diag.FileName), Diag.Line, Diag.Column,
     Diag.RuleId, EscapeGithubData(Diag.Message)]);
end;

function SeverityName(Sev: TSeverity): string;
begin
  case Sev of
    svWarning: Result := 'warning';
  else
    Result := 'warning';
  end;
end;

function FormatDiagnosticsJson(const Diags: TDiagnosticList): string;
var
  Arr: TJSONArray;
  Obj: TJSONObject;
  Diag: TDiagnostic;
begin
  // fpjsonでの組み立て(RawpacoConfig.pasが読み込み側で既に使っている依存を
  // 出力側でも再利用する)。文字列の引用符・制御文字のエスケープをAsJSONに
  // 任せることで、Format('%s'...)による手書きエスケープの漏れを避ける。
  Arr := TJSONArray.Create;
  try
    for Diag in Diags do
    begin
      Obj := TJSONObject.Create;
      Obj.Add('ruleId', Diag.RuleId);
      Obj.Add('file', Diag.FileName);
      Obj.Add('line', Integer(Diag.Line));
      Obj.Add('column', Integer(Diag.Column));
      Obj.Add('severity', SeverityName(Diag.Severity));
      Obj.Add('message', Diag.Message);
      Arr.Add(Obj);
    end;
    Result := Arr.AsJSON;
  finally
    Arr.Free; // TJSONArray.Freeは追加済みの要素(TJSONObject)も再帰的に解放する
  end;
end;

function SplitSourceLines(const Source: AnsiString): TStringArray;
var
  Lines: TStringArray;
  Count, Start, I: Integer;
begin
  SetLength(Lines, 0);
  Count := 0;
  Start := 1;
  for I := 1 to Length(Source) do
  begin
    if Source[I] = #10 then
    begin
      SetLength(Lines, Count + 1);
      Lines[Count] := Copy(Source, Start, I - Start);
      Inc(Count);
      Start := I + 1;
    end;
  end;
  SetLength(Lines, Count + 1);
  Lines[Count] := Copy(Source, Start, Length(Source) - Start + 1);
  Result := Lines;
end;

// "// rawpaco:ignore RAWPACO-XXX-001 何かコメント" のような行から、
// "rawpaco:ignore"直後の空白区切りトークン(RuleId部分)だけを取り出す。
// 見つからなければ空文字列を返す。
function ExtractIgnoredRuleId(const Line: string): string;
const
  CMarker = 'rawpaco:ignore';
var
  P, Q: Integer;
  Rest: string;
begin
  Result := '';
  P := Pos(CMarker, Line);
  if P = 0 then
    Exit;
  Rest := Trim(Copy(Line, P + Length(CMarker), Length(Line)));
  Q := 1;
  while (Q <= Length(Rest)) and not (Rest[Q] in [' ', #9]) do
    Inc(Q);
  Result := Copy(Rest, 1, Q - 1);
end;

function IsDiagnosticSuppressed(const Lines: TStringArray;
  const Diag: TDiagnostic): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  Idx := Integer(Diag.Line) - 1; // Diag.Lineは1-origin、Linesは0-origin
  if (Idx >= 0) and (Idx < Length(Lines)) and
     (ExtractIgnoredRuleId(Lines[Idx]) = Diag.RuleId) then
    Exit(True);
  if (Idx - 1 >= 0) and (Idx - 1 < Length(Lines)) and
     (ExtractIgnoredRuleId(Lines[Idx - 1]) = Diag.RuleId) then
    Exit(True);
end;

end.
