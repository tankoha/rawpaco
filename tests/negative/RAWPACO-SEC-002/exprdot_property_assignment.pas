program ExprDotPropertySecret;

{$mode objfpc}{$H+}

type
  TConnection = class
    Password: string;
  end;

var
  Conn: TConnection;
begin
  Conn := TConnection.Create;
  Conn.Password := 'hunter2';
  WriteLn('connected');
end.
