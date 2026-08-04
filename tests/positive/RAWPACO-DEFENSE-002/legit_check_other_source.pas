program LegitCheckOtherSource;

{$mode objfpc}{$H+}

type
  TFoo = class
  end;

function MaybeGetFoo: TFoo;
begin
  Result := nil;
end;

var
  Obj: TFoo;
begin
  Obj := MaybeGetFoo;
  if Assigned(Obj) then
    WriteLn('ok');
end.
