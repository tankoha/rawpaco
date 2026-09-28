unit objfpc_then_delphi;
{$mode objfpc}{$H+}
interface
function F: string;
implementation
{$mode delphi}
{$H-}
function F: string;
begin
  Result := '';
end;
end.
