unit free_in_except_and_body;
{$mode objfpc}{$H+}
interface
implementation
uses Classes;
// 「後始末して投げ直す」定型。except 配下の解放も保護に数える。
procedure CleanupAndReraise;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add('x');
    L.Free;
  except
    L.Free;
    raise;
  end;
end;
end.
