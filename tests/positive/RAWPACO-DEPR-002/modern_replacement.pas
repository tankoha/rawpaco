unit modern_replacement;

// deprecated ではない現行 API（GetTickCount64）を使っている例。
// 名前が似ているだけの GetTickCount64 を GetTickCount と取り違えないこと。

interface

uses
  SysUtils;

function Elapsed: QWord;

implementation

function Elapsed: QWord;
begin
  Result := GetTickCount64;
end;

end.
