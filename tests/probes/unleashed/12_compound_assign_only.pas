{$mode unleashed}
program CompoundAssignOnly;
// 対照群2: `+=` は FPC 既存機能({$COPERATORS ON})。08 の lock 文の
// ERROR が `+=` 由来でないことを切り分けるため単独で確かめる。
var
  total, n: Integer;
begin
  total += n;
end.
