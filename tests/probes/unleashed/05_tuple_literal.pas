{$mode unleashed}
program TupleLiteral;
// tuples: タプル型・タプルリテラル(位置指定 / 名前付き)・仮引数での分割
procedure show(p: (Integer, Integer));
begin
end;
procedure process((x, y): (Integer, Integer));
begin
end;
var
  r: (a: Integer; b: Integer);
begin
  r := (10, 20);
  r := (a: 10, b: 20);
  show((1, 2));
end.
