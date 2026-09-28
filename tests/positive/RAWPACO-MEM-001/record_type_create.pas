unit record_type_create;
{$mode objfpc}{$H+}
interface
implementation
uses Classes, SysUtils;
type
  TPoint3 = record
    X: Integer;
    class function Create(AX: Integer): TPoint3; static;
  end;
class function TPoint3.Create(AX: Integer): TPoint3;
begin
  Result.X := AX;
end;
procedure UsesRecord;
var
  P: TPoint3;
begin
  P := TPoint3.Create(1);
end;
end.
