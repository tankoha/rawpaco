unit freeandnil_in_finally;
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
    FreeAndNil(L);
  end;
end;
end.
