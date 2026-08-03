program BothLiterals;

{$mode objfpc}{$H+}

var
  Sql: string;
begin
  Sql := 'SELECT * FROM users WHERE id=' + '1';
  WriteLn(Sql);
end.
