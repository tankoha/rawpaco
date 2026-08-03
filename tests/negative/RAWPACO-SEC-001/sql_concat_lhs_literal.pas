program SqlConcatLhsLiteral;

{$mode objfpc}{$H+}

var
  UserInput, Sql: string;
begin
  UserInput := ParamStr(1);
  Sql := 'SELECT * FROM users WHERE id=' + UserInput;
  WriteLn(Sql);
end.
