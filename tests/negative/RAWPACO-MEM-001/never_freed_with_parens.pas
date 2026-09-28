unit never_freed_with_parens;
{$mode objfpc}{$H+}
interface
implementation
uses Classes;
procedure Leak;
var
  L: TStringList;
begin
  L := TStringList.Create();
  L.Clear;
end;
end.
