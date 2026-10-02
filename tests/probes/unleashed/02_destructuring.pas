{$mode unleashed}
program Destructuring;
// tuples: 分割代入(inline var 形 / 既存変数への多重代入 / ワイルドカード)
function getPair: (Integer, Integer);
begin
  Result := (10, 20);
end;
var
  x, y: Integer;
begin
  var (a, b) := getPair;
  (x, y) := getPair;
  var (first, _, _, last) := getQuad;
  WriteLn(a, b, x, y, first, last);
end.
