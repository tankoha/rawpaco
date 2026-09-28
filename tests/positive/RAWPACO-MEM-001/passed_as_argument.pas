unit passed_as_argument;
{$mode objfpc}{$H+}
interface
implementation
uses Classes, SysUtils;
procedure Handover(AOwner: TStringList);
var
  L: TStringList;
begin
  L := TStringList.Create;
  AOwner.AddObject('k', L);
end;
end.
