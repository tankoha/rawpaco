unit reassigned_twice;
{$mode objfpc}{$H+}
interface
implementation
uses Classes, SysUtils;
procedure Reassigned;
var
  L: TStringList;
begin
  L := TStringList.Create;
  L.Free;
  L := TStringList.Create;
  L.Free;
end;
end.
