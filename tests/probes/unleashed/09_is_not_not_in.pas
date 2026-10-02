{$mode unleashed}
program IsNotNotIn;
// quality-of-life: `is not` / `not in` 演算子
var
  obj: TObject;
  x: Integer;
begin
  if obj is not TObject then
    WriteLn('no');
  if x not in [1, 2] then
    WriteLn('no');
end.
