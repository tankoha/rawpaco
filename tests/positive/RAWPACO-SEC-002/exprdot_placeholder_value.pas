program ExprDotPlaceholderSecret;

{$mode objfpc}{$H+}

type
  TConnection = class
    Password: string;
  end;

var
  Conn: TConnection;
begin
  Conn := TConnection.Create;
  Conn.Password := 'CHANGE_ME';
  WriteLn('connected');
end.
