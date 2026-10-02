{$mode unleashed}
program MultiVarInit;
// multi-var init: 宣言部で複数変数に1つの初期化子
var
  a, b, c: Integer = 42;
begin
  WriteLn(a, b, c);
end.
