program ExprDotNestedPropertySecret;

{$mode objfpc}{$H+}

type
  TDbSettings = class
    ConnectionString: string;
  end;

  TConfig = class
    Db: TDbSettings;
  end;

var
  Config: TConfig;
begin
  Config := TConfig.Create;
  Config.Db := TDbSettings.Create;
  Config.Db.ConnectionString := 'Server=x;Password=hunter2;';
  WriteLn('configured');
end.
