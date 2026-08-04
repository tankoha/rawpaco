program RedundantCheckWithParens;

{$mode objfpc}{$H+}

type
  TFoo = class
    constructor Create(AValue: Integer);
  end;

constructor TFoo.Create(AValue: Integer);
begin
end;

var
  Obj: TFoo;
begin
  Obj := TFoo.Create(42);
  if Assigned(Obj) then
    WriteLn('ok');
end.
