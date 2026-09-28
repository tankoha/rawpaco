unit free_outside_finally;
{$mode objfpc}{$H+}
interface
implementation
uses Classes;
procedure MayLeakOnException;
var
  L: TStringList;
begin
  L := TStringList.Create;
  L.Add('x');
  L.Free;
end;
end.
