program CallWithoutParens;

{$mode objfpc}{$H+}

procedure OldProc; deprecated;
begin
  WriteLn('old');
end;

begin
  OldProc;
end.
