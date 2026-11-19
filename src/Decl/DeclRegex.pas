unit DeclRegex;

{$mode objfpc}{$H+}

// 宣言的ルールの正規表現（`pattern-regex` / `pattern-not-regex` / `metavariable-regex`、
// 設計書 OPENGREP_RULE_ENGINE_DESIGN 4.4〜4.6）。エンジンは FPC 同梱の RegExpr
// （未決 #8 の決定）。tree-sitter に依存させず、単体テスト（tests/unit）で確かめる。
//
// RegExpr（v0.987）は freepascal.org の 3.2.2 のリファレンスに載っておらず、使い方は
// 実機で確かめた（CLAUDE.md ルール1 の例外。設計書 4.6、2026-11-19 の追加確認を含む）:
// - 既定は ModifierS = True（`.` が改行にも一致）、ModifierM = False。opengrep（PCRE2）に
//   合わせて ModifierS = False、ModifierM = True（`^` / `$` が各行の先頭・末尾）にする
// - ModifierI を変えると次の Exec から効く
// - ExecNext は長さ 0 の一致の後も先へ進むので、繰り返しは必ず終わる
// - 名前付きグループ・先読み・後読みなどは ERegExpr（コンパイルエラー）になるが、
//   `[[:alpha:]]` のような POSIX の文字クラスはエラーにならず黙って誤解釈される

interface

uses
  SysUtils, RegExpr;

type
  // 0 始まりのバイト位置の [StartByte, EndByte)。tree-sitter の位置と同じ数え方。
  TRegexRange = record
    StartByte, EndByte: LongWord;
  end;
  TRegexRangeArray = array of TRegexRange;

  // 各行の先頭の 0 始まりのバイト位置。要素 0 は常に 0。
  TLineStarts = array of LongWord;

// Expr を上の設定でコンパイルして返す（呼び出し側が Free する）。CaseInsensitive なら
// ModifierI = True。失敗したら nil を返し、Err に理由を入れる:
// - Expr が空: 'empty regex'
// - POSIX の文字クラス（`[:` + 英小文字 1 字以上 + `:]` の並び）を含む:
//   'POSIX character classes such as [[:alpha:]] are not supported'
// - ERegExpr: 'invalid or unsupported regex: ' + 例外のメッセージ
function CompileRuleRegex(const Expr: string; CaseInsensitive: Boolean; out Err: string): TRegExpr;

// Source の中の一致を、重ならない順に全部返す。長さ 0 の一致は返さない（範囲として
// 報告できず、`a*` のようなパターンが全位置に一致してしまうため）。
function FindRegexRanges(Re: TRegExpr; const Source: string): TRegexRangeArray;

// metavariable-regex の判定。S の先頭から一致すれば True（先頭に固定する。opengrep の
// 説明に合わせ、固定しない場合より一致を絞る側に倒す。CLAUDE.md ルール5）。
// 長さ 0 の一致でも先頭なら True。
function RegexMatchesAtStart(Re: TRegExpr; const S: string): Boolean;

// 行の先頭位置の表。改行は #10 だけを数える（tree-sitter と同じ）。
function ComputeLineStarts(const Source: string): TLineStarts;

// バイト位置 Offset を 0 始まりの行と、行頭からのバイト数に変える。
procedure OffsetToRowCol(const LS: TLineStarts; Offset: LongWord; out Row, Col: LongWord);

implementation

function CompileRuleRegex(const Expr: string; CaseInsensitive: Boolean; out Err: string): TRegExpr;
var
  i, j: Integer;
  Re: TRegExpr;
begin
  Result := nil;
  Err := '';

  if Expr = '' then
  begin
    Err := 'empty regex';
    Exit;
  end;

  // RegExpr は POSIX クラスをエラーにせず誤解釈するため、事前検出して拒否する
  i := 1;
  while i <= Length(Expr) do
  begin
    if (Expr[i] = '[') and (i + 1 <= Length(Expr)) and (Expr[i + 1] = ':') then
    begin
      j := i + 2;
      if (j <= Length(Expr)) and (Expr[j] in ['a'..'z']) then
      begin
        while (j <= Length(Expr)) and (Expr[j] in ['a'..'z']) do
          Inc(j);
        if (j <= Length(Expr)) and (Expr[j] = ':') and
           (j + 1 <= Length(Expr)) and (Expr[j + 1] = ']') then
        begin
          Err := 'POSIX character classes such as [[:alpha:]] are not supported';
          Exit;
        end;
      end;
    end;
    Inc(i);
  end;

  Re := TRegExpr.Create;
  try
    Re.Expression := Expr;
    Re.ModifierS := False;
    Re.ModifierM := True;
    Re.ModifierI := CaseInsensitive;
    Re.Compile;
  except
    on E: ERegExpr do
    begin
      Re.Free;
      Err := 'invalid or unsupported regex: ' + E.Message;
      Exit;
    end;
  end;
  Result := Re;
end;

function FindRegexRanges(Re: TRegExpr; const Source: string): TRegexRangeArray;
var
  R: TRegexRange;
  Found: Boolean;
begin
  Result := nil;
  if Source = '' then
    Exit;
  // Exec は毎回先頭から探し直すので、ループの条件には ExecNext の結果を使う。
  Found := Re.Exec(Source);
  while Found do
  begin
    if Re.MatchLen[0] > 0 then
    begin
      R.StartByte := Re.MatchPos[0] - 1;
      R.EndByte := R.StartByte + Re.MatchLen[0];
      SetLength(Result, Length(Result) + 1);
      Result[Length(Result) - 1] := R;
    end;
    Found := Re.ExecNext;
  end;
end;

function RegexMatchesAtStart(Re: TRegExpr; const S: string): Boolean;
begin
  Result := Re.Exec(S) and (Re.MatchPos[0] = 1);
end;

function ComputeLineStarts(const Source: string): TLineStarts;
var
  i, idx: Integer;
begin
  Result := nil;
  idx := 0;
  for i := 1 to Length(Source) do
    if Source[i] = #10 then
      Inc(idx);
  SetLength(Result, idx + 1);
  Result[0] := 0;
  idx := 1;
  for i := 1 to Length(Source) do
  begin
    if Source[i] = #10 then
    begin
      Result[idx] := i;
      Inc(idx);
    end;
  end;
end;

procedure OffsetToRowCol(const LS: TLineStarts; Offset: LongWord; out Row, Col: LongWord);
var
  lo, hi, mid: Integer;
begin
  // LS[k] <= Offset を満たす最大の k を二分探索（添字は Integer でアンダーフローを避ける）
  lo := 0;
  hi := Length(LS) - 1;
  while lo < hi do
  begin
    mid := lo + (hi - lo + 1) div 2;
    if LS[mid] <= Offset then
      lo := mid
    else
      hi := mid - 1;
  end;
  Row := lo;
  Col := Offset - LS[lo];
end;

end.
