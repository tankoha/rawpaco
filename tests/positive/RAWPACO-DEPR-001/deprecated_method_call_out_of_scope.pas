program DeprecatedMethodCallOutOfScope;

{$mode objfpc}{$H+}

type
  TFoo = class
    procedure OldMethod; deprecated;
  end;

procedure TFoo.OldMethod;
begin
  WriteLn('old method');
end;

var
  F: TFoo;
begin
  F := TFoo.Create;
  F.OldMethod;
end.
