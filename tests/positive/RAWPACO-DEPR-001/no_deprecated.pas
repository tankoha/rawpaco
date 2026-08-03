program NoDeprecated;

{$mode objfpc}{$H+}

procedure NormalProc;
begin
  WriteLn('normal');
end;

begin
  NormalProc;
  NormalProc();
end.
