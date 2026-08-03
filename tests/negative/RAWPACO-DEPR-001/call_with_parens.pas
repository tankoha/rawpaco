program CallWithParens;

{$mode objfpc}{$H+}

procedure OldProc; deprecated 'use NewProc instead';
begin
  WriteLn('old');
end;

begin
  OldProc();
end.
