unit freeandnil_outside_finally;
{$mode objfpc}{$H+}
interface
implementation
uses Classes, SysUtils;
procedure MayLeakOnException;
var
  L: TStringList;
begin
  L := TStringList.Create;
  L.Add('x');
  FreeAndNil(L);
end;
end.
