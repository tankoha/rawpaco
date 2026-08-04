program ExprDotNonLiteralSecret;

{$mode objfpc}{$H+}

type
  TConnection = class
    Password: string;
  end;

function GetPassword: string;
begin
  Result := 'runtime-value';
end;

var
  Conn: TConnection;
begin
  Conn := TConnection.Create;
  Conn.Password := GetPassword();
  WriteLn('connected');
end.
