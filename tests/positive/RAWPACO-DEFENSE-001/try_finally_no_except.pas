program TryFinallyNoExcept;

{$mode objfpc}{$H+}

var
  F: Text;
begin
  AssignFile(F, 'dummy.txt');
  try
    Rewrite(F);
    WriteLn(F, 'hello');
  finally
    CloseFile(F);
  end;
end.
