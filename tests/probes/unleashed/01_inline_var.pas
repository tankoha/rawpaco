{$mode unleashed}
program InlineVar;
// modeswitch inlinevars: begin..end 内の var 宣言(型推論・ブロックスコープ)
begin
  var x: Integer;
  var y: Integer := 42;
  var z := 100;
  var s := 'hello';
  x := y + z;
  WriteLn(x, s);
end.
