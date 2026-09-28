unit never_freed;
{$mode objfpc}{$H+}
interface
implementation
uses Classes;
procedure Leak;
var
  L: TStringList;
begin
  L := TStringList.Create;
  L.Add('x');
end;
end.
