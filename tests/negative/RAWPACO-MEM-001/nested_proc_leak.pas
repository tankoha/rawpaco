unit nested_proc_leak;
{$mode objfpc}{$H+}
interface
implementation
uses Classes;
procedure Outer;

  procedure Inner;
  var
    M: TStringList;
  begin
    M := TStringList.Create;
    M.Add('y');
  end;

begin
  Inner;
end;
end.
