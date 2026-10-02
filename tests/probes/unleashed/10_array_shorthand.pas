{$mode unleashed}
program ArrayShorthand;
// array[N] of T は array[0..N-1] of T の省略形
var
  a: array[10] of Integer;
begin
  a[0] := 1;
end.
