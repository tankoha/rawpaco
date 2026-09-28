unit returned_to_caller;
{$mode objfpc}{$H+}
interface
implementation
uses Classes, SysUtils;
function Make: TStringList;
var
  L: TStringList;
begin
  L := TStringList.Create;
  L.Add('x');
  Result := L;
end;
end.
