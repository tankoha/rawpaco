program VarWithInitializerSecret;

{$mode objfpc}{$H+}

var
  DbConnectionString: string = 'Server=prod;User=admin;Password=hunter2;';
begin
  WriteLn(DbConnectionString);
end.
