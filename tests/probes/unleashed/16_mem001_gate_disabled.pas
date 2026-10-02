{$mode unleashed}
program Mem001GateDisabled;
// ルール挙動の確認: 同一ファイル内に本物の解放漏れ(Leak)があっても、
// 別の手続きに defer が1つあるだけで RAWPACO-MEM-001 の門番
// (ts_node_has_error)が真になり、ファイル全体で検知が止まることを示す。
// 対照群は同じ内容から defer 行だけを除いたもの(HANDOFF.md 参照)。
procedure Leak;
var
  o: TObject;
begin
  o := TObject.Create;
  WriteLn(o.ClassName);
end;
procedure Ok;
var
  p: TObject;
begin
  p := TObject.Create;
  defer p.Free;
  WriteLn(p.ClassName);
end;
begin
  Leak;
  Ok;
end.
