program DeprecatedButUnused;

{$mode objfpc}{$H+}

procedure OldProc; deprecated;
begin
  WriteLn('old');
end;

begin
  WriteLn('never calling OldProc');
end.
