program TestDeclRegex;

{$mode objfpc}{$H+}

// DeclRegex（宣言的ルールの正規表現）の単体テスト。期待値は実装からではなく
// 仕様（src/Decl/DeclRegex.pas の interface のコメント）から書いている。

uses
  SysUtils, RegExpr, DeclRegex;

var
  Failures: Integer;
  Total: Integer;

procedure CheckEq(const Name, Got, Want: string);
begin
  Inc(Total);
  if Got <> Want then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', Name);
    WriteLn('  want: [', Want, ']');
    WriteLn('  got:  [', Got, ']');
  end;
end;

// コンパイルの結果を 'ok' か 'error: <理由>' にする。
function CompileResult(const Expr: string): string;
var
  Re: TRegExpr;
  Err: string;
begin
  Re := CompileRuleRegex(Expr, False, Err);
  if Re = nil then
    Result := 'error: ' + Err
  else
  begin
    Result := 'ok';
    Re.Free;
  end;
end;

// 一致を `開始-終了` の並びにする。コンパイルできなければ 'error'。
function RangesOf(const Expr, Source: string; CaseInsensitive: Boolean): string;
var
  Re: TRegExpr;
  Err: string;
  R: TRegexRangeArray;
  I: Integer;
begin
  Re := CompileRuleRegex(Expr, CaseInsensitive, Err);
  if Re = nil then
    Exit('error');
  try
    R := FindRegexRanges(Re, Source);
    Result := '';
    for I := 0 to High(R) do
    begin
      if I > 0 then
        Result := Result + ' ';
      Result := Result + Format('%d-%d', [R[I].StartByte, R[I].EndByte]);
    end;
  finally
    Re.Free;
  end;
end;

function AtStart(const Expr, S: string; CaseInsensitive: Boolean): string;
var
  Re: TRegExpr;
  Err: string;
begin
  Re := CompileRuleRegex(Expr, CaseInsensitive, Err);
  if Re = nil then
    Exit('error');
  try
    Result := BoolToStr(RegexMatchesAtStart(Re, S), 'T', 'F');
  finally
    Re.Free;
  end;
end;

function RowCol(const Source: string; Offset: LongWord): string;
var
  LS: TLineStarts;
  Row, Col: LongWord;
begin
  LS := ComputeLineStarts(Source);
  OffsetToRowCol(LS, Offset, Row, Col);
  Result := Format('%d:%d', [Row, Col]);
end;

function LineStartsOf(const Source: string): string;
var
  LS: TLineStarts;
  I: Integer;
begin
  LS := ComputeLineStarts(Source);
  Result := '';
  for I := 0 to High(LS) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + IntToStr(LS[I]);
  end;
end;

begin
  Failures := 0;
  Total := 0;

  // コンパイル
  CheckEq('compile plain', CompileResult('Get[A-Z]\w*'), 'ok');
  CheckEq('compile empty', CompileResult(''), 'error: empty regex');
  CheckEq('compile posix', CompileResult('[[:alpha:]]+'),
    'error: POSIX character classes such as [[:alpha:]] are not supported');
  CheckEq('compile posix in set', CompileResult('[a[:digit:]]'),
    'error: POSIX character classes such as [[:alpha:]] are not supported');
  CheckEq('compile bracket colon not posix', CompileResult('[:]'), 'ok');
  CheckEq('compile named group', Copy(CompileResult('(?<n>x)'), 1, 36),
    'error: invalid or unsupported regex:');
  CheckEq('compile lookahead', Copy(CompileResult('a(?=b)'), 1, 36),
    'error: invalid or unsupported regex:');

  // 範囲（0 始まりのバイト位置、[開始, 終了)）
  CheckEq('ranges basic', RangesOf('ab', 'xabyab', False), '1-3 4-6');
  CheckEq('ranges none', RangesOf('zz', 'xabyab', False), '');
  CheckEq('ranges skip empty', RangesOf('x*', 'axxb', False), '1-3');
  CheckEq('ranges dot no newline', RangesOf('a.b', 'a' + #10 + 'b axb', False), '4-7');
  CheckEq('ranges multiline anchors', RangesOf('^b.c$', 'a' + #10 + 'bxc' + #10 + 'byc', False), '2-5 6-9');
  CheckEq('ranges case sensitive', RangesOf('get', 'GetValue get', False), '9-12');
  CheckEq('ranges case insensitive', RangesOf('get', 'GetValue get', True), '0-3 9-12');

  // 先頭からの一致
  CheckEq('at start yes', AtStart('Get', 'GetValue', False), 'T');
  CheckEq('at start later only', AtStart('Value', 'GetValue', False), 'F');
  CheckEq('at start case', AtStart('get', 'GetValue', False), 'F');
  CheckEq('at start case insensitive', AtStart('get', 'GetValue', True), 'T');
  CheckEq('at start empty match', AtStart('x*', 'abc', False), 'T');
  CheckEq('at start anchored end', AtStart('^Get$', 'GetValue', False), 'F');

  // 行の先頭と行・列
  CheckEq('line starts', LineStartsOf('ab' + #10 + 'c' + #10), '0,3,5');
  CheckEq('line starts crlf', LineStartsOf('a' + #13#10 + 'b'), '0,3');
  CheckEq('line starts empty', LineStartsOf(''), '0');
  CheckEq('rowcol first', RowCol('ab' + #10 + 'cd', 1), '0:1');
  CheckEq('rowcol second line', RowCol('ab' + #10 + 'cd', 4), '1:1');
  CheckEq('rowcol line start', RowCol('ab' + #10 + 'cd', 3), '1:0');
  CheckEq('rowcol at newline', RowCol('ab' + #10 + 'cd', 2), '0:2');
  CheckEq('rowcol end', RowCol('ab' + #10 + 'cd', 5), '1:2');

  if Failures > 0 then
  begin
    WriteLn('TestDeclRegex: ', Failures, ' of ', Total, ' case(s) failed');
    Halt(1);
  end
  else
    WriteLn('TestDeclRegex: all ', Total, ' cases passed');
end.
