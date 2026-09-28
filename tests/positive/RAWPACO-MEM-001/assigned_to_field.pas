unit assigned_to_field;
{$mode objfpc}{$H+}
interface
implementation
uses Classes, SysUtils;
type
  THolder = class
    FList: TStringList;
    procedure Build;
  end;
procedure THolder.Build;
var
  L: TStringList;
begin
  L := TStringList.Create;
  FList := L;
end;
end.
