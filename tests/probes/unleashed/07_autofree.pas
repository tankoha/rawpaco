{$mode unleashed}
program Autofree;
// scoped cleanup: autofree(スコープ終了時に解放。finally 不要)
uses Classes;
begin
  var list := autofree TStringList.Create;
  list.Add('x');
  var log := autofree TStringList.Create;
  log.Add('y');
end.
