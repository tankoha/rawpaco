unit freed_in_nested_proc;
{$mode objfpc}{$H+}
interface
implementation
uses Classes, SysUtils;
// 解放をネストした手続きに委ねる形。外側の走査は生成を数えず、解放は数える。
procedure Outer;
var
  L: TStringList;

  procedure Cleanup;
  begin
    L.Free;
  end;

begin
  L := TStringList.Create;
  try
    L.Add('x');
  finally
    Cleanup;
  end;
end;
end.
