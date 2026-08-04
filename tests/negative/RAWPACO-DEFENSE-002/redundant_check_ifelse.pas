program RedundantCheckIfElse;

{$mode objfpc}{$H+}

type
  TFoo = class
  end;

var
  Obj: TFoo;
begin
  Obj := TFoo.Create;
  if Assigned(Obj) then
    WriteLn('ok')
  else
    WriteLn('unreachable');
end.
