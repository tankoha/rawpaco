unit shadowed_by_local_declaration;

// ファイル自身が同名の識別子を宣言している場合、スコープ解決ができない以上
// RTL のシンボルを指しているとは断定できないので検知しない。

interface

uses
  SysUtils;

function Build: string;

implementation

function Build: string;
var
  DecimalSeparator: Char;
  GetTickCount: LongWord;
begin
  DecimalSeparator := ',';
  GetTickCount := 0;
  Result := DecimalSeparator + IntToStr(GetTickCount);
end;

end.
