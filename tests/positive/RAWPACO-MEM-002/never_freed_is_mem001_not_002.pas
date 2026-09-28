unit never_freed_is_mem001_not_002;
{$mode objfpc}{$H+}
interface
implementation
uses Classes;
// 解放が1つも無い場合は MEM-001 の担当。MEM-002 は発火してはいけない。
procedure Leak;
var
  L: TStringList;
begin
  // rawpaco:ignore RAWPACO-MEM-001
  L := TStringList.Create;
  L.Add('x');
end;
end.
