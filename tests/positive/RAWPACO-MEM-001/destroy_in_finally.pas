unit destroy_in_finally;
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
    L.Destroy;
  end;
end;
end.
