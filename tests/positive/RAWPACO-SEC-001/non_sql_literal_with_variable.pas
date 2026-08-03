program NonSqlLiteralWithVariable;

{$mode objfpc}{$H+}

var
  UserName, Greeting: string;
begin
  UserName := ParamStr(1);
  Greeting := 'Hello, ' + UserName;
  WriteLn(Greeting);
end.
