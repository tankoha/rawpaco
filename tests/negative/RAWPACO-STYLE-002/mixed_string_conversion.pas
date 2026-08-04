unit MixedStringConversion;

// 検知されるべき: SysUtilsのStrToInt(EConvertErrorを送出しうる)が、
// 片方ではtry-exceptで保護され、もう片方では素通しになっている。

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

function ParseSafely(const AText: string): Integer;
function ParseDirect(const AText: string): Integer;

implementation

function ParseSafely(const AText: string): Integer;
begin
  try
    Result := StrToInt(AText);
  except
    on E: EConvertError do
    begin
      WriteLn('not a number: ', E.Message);
      Result := 0;
    end;
  end;
end;

function ParseDirect(const AText: string): Integer;
begin
  Result := StrToInt(AText);
end;

end.
