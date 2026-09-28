unit interface_variable;
{$mode objfpc}{$H+}
interface
implementation
uses Classes, SysUtils;
procedure UsesInterface;
var
  I: IInterface;
begin
  I := TInterfacedObject.Create;
end;
end.
