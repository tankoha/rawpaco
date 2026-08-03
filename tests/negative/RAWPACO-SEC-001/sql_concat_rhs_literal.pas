program SqlConcatRhsLiteral;

{$mode objfpc}{$H+}

var
  Prefix, Sql: string;
begin
  Prefix := ParamStr(1);
  Sql := Prefix + ' SELECT * FROM users';
  WriteLn(Sql);
end.
