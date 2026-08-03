unit deprecated_function;

// SysUtils.GetTickCount は `deprecated 'Use GetTickCount64 instead'` 付き。

interface

uses
  SysUtils;

function Elapsed: LongWord;

implementation

function Elapsed: LongWord;
begin
  Result := GetTickCount;
end;

end.
