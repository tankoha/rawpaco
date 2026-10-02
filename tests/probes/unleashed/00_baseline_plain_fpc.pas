{$mode unleashed}
program Baseline;
// 対照群: Unleashed 固有構文を一切含まない。{$mode unleashed} 指令そのものが
// ERROR の原因にならないことを確かめる。
var
  i, total: Integer;
begin
  total := 0;
  for i := 1 to 10 do
    total := total + i;
  WriteLn(total);
end.
