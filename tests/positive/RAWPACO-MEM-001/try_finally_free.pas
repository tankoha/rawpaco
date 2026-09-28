unit try_finally_free;
{$mode objfpc}{$H+}
interface
implementation
uses Classes, SysUtils;
procedure Correct;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add('x');
  finally
    L.Free;
  end;
end;
end.
