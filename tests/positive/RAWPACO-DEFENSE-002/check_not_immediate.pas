program CheckNotImmediate;

{$mode objfpc}{$H+}

type
  TFoo = class
  end;

var
  Obj: TFoo;
begin
  Obj := TFoo.Create;
  WriteLn('doing something else in between');
  if Assigned(Obj) then
    WriteLn('ok');
end.
