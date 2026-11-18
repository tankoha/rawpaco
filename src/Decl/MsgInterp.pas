unit MsgInterp;

{$mode objfpc}{$H+}

// 宣言的ルールの `message` に書かれた `$X` / `$...X` を、一致で束縛されたテキストに
// 置き換える（設計書 OPENGREP_RULE_ENGINE_DESIGN 4.7）。tree-sitter に依存させず、
// 束縛は「キーと値の文字列の組」で受け取る。単体テスト（tests/unit）で確かめるため。
//
// 字句の規則はパターン側（PatLexer）と揃える: `$` の直後の名前は英大文字・数字・`_` から
// 成り、先頭は英大文字か `_`。最長一致で切るので `$XY` は `$X` + `Y` にならない。
// `$...` の直後に名前が続けば `$...X`。それ以外の `$` はそのまま残す。

interface

uses
  SysUtils;

type
  TMsgVarRef = record
    // `$` や `$...` を除いた名前部分。
    Name: string;
    // `$...X` のとき True。
    IsEllipsis: Boolean;
    // Msg 上の位置（1 始まり）と、`$` から名前の末尾までの長さ。
    StartPos, Len: Integer;
  end;
  TMsgVarRefArray = array of TMsgVarRef;

// Msg に現れる参照を出現順に返す（重複もそのまま返す）。
function FindMessageMetaVars(const Msg: string): TMsgVarRefArray;

// 束縛のキー。`$X` は 'X'、`$...X` は '...X'。照合器（PatMatcher）は両者を同じ名前で
// 持つが、メッセージでは書き分けたとおりにだけ置き換える（`$X` に範囲の束縛は入れない）。
function BindingKey(const Name: string; IsEllipsis: Boolean): string;

// Msg 中の参照を、Keys[i] に一致するものは Values[i] で置き換える。一致しない参照
// （束縛されていない名前や `$_`）は書かれたまま残す。Keys と Values は同じ長さ。
// 値の中の空白・改行・タブの並びは空白 1 個にまとめ、前後の空白を落とす。
// 複数行の束縛がそのまま入ると、1 診断 1 行の text / github 形式の出力が壊れるため。
function InterpolateMessage(const Msg: string; const Keys, Values: array of string): string;

implementation

function IsNameStart(c: Char): Boolean;
begin
  Result := (c >= 'A') and (c <= 'Z') or (c = '_');
end;

function IsNameChar(c: Char): Boolean;
begin
  Result := IsNameStart(c) or ((c >= '0') and (c <= '9'));
end;

function NormalizeValue(const S: string): string;
var
  i: Integer;
  inSpace: Boolean;
begin
  Result := '';
  inSpace := False;
  for i := 1 to Length(S) do
  begin
    if (S[i] = ' ') or (S[i] = #9) or (S[i] = #10) or (S[i] = #13) then
    begin
      if not inSpace and (Length(Result) > 0) then
        Result := Result + ' ';
      inSpace := True;
    end
    else
    begin
      Result := Result + S[i];
      inSpace := False;
    end;
  end;
  if inSpace and (Length(Result) > 0) then
    SetLength(Result, Length(Result) - 1);
end;

function FindMessageMetaVars(const Msg: string): TMsgVarRefArray;
var
  i, nameStart, nameLen, msgLen: Integer;
  refs: TMsgVarRefArray;
begin
  refs := nil;
  msgLen := Length(Msg);
  i := 1;
  while i <= msgLen do
  begin
    if Msg[i] <> '$' then
    begin
      Inc(i);
      Continue;
    end;

    if (i + 3 <= msgLen)
      and (Msg[i+1] = '.') and (Msg[i+2] = '.') and (Msg[i+3] = '.')
      and (i + 4 <= msgLen) and IsNameStart(Msg[i+4]) then
    begin
      nameStart := i + 4;
      nameLen := 0;
      while (nameStart + nameLen <= msgLen) and IsNameChar(Msg[nameStart + nameLen]) do
        Inc(nameLen);
      SetLength(refs, Length(refs) + 1);
      refs[Length(refs)-1].Name := Copy(Msg, nameStart, nameLen);
      refs[Length(refs)-1].IsEllipsis := True;
      refs[Length(refs)-1].StartPos := i;
      refs[Length(refs)-1].Len := 4 + nameLen;
      i := i + 4 + nameLen;
    end
    else if (i + 1 <= msgLen) and IsNameStart(Msg[i+1]) then
    begin
      nameStart := i + 1;
      nameLen := 0;
      while (nameStart + nameLen <= msgLen) and IsNameChar(Msg[nameStart + nameLen]) do
        Inc(nameLen);
      SetLength(refs, Length(refs) + 1);
      refs[Length(refs)-1].Name := Copy(Msg, nameStart, nameLen);
      refs[Length(refs)-1].IsEllipsis := False;
      refs[Length(refs)-1].StartPos := i;
      refs[Length(refs)-1].Len := 1 + nameLen;
      i := i + 1 + nameLen;
    end
    else
      Inc(i);
  end;
  Result := refs;
end;

function BindingKey(const Name: string; IsEllipsis: Boolean): string;
begin
  if IsEllipsis then
    Result := '...' + Name
  else
    Result := Name;
end;

function InterpolateMessage(const Msg: string; const Keys, Values: array of string): string;
var
  refs: TMsgVarRefArray;
  i, j, cur, msgLen: Integer;
  key: string;
  found: Boolean;
begin
  Result := '';
  refs := FindMessageMetaVars(Msg);
  msgLen := Length(Msg);
  cur := 1;
  for i := 0 to High(refs) do
  begin
    if refs[i].StartPos > cur then
      Result := Result + Copy(Msg, cur, refs[i].StartPos - cur);

    key := BindingKey(refs[i].Name, refs[i].IsEllipsis);
    found := False;
    for j := 0 to High(Keys) do
    begin
      if Keys[j] = key then
      begin
        Result := Result + NormalizeValue(Values[j]);
        found := True;
        Break;
      end;
    end;
    if not found then
      Result := Result + Copy(Msg, refs[i].StartPos, refs[i].Len);

    cur := refs[i].StartPos + refs[i].Len;
  end;
  if cur <= msgLen then
    Result := Result + Copy(Msg, cur, msgLen - cur + 1);
end;

end.
