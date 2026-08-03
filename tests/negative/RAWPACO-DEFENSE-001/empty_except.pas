program EmptyExcept;

{$mode objfpc}{$H+}

begin
  try
    WriteLn('work');
  except
  end;
end.
