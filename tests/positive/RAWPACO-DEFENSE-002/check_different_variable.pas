program CheckDifferentVariable;

{$mode objfpc}{$H+}

type
  TFoo = class
  end;

var
  Obj1, Obj2: TFoo;
begin
  Obj1 := TFoo.Create;
  if Assigned(Obj2) then
    WriteLn('ok');
end.
