unit free_in_finally;
{$mode objfpc}{$H+}
interface
implementation
uses Classes;
procedure Correct;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add('x');
  finally
    L.Free;
  end;
end;
end.
