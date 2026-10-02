{$mode unleashed}
program Mem001DeferLocal;
// ルール挙動の確認: defer で解放している手続きローカル変数を
// RAWPACO-MEM-001 がどう扱うか(Unleashed の意味では解放漏れではない)
procedure Work;
var
  o: TObject;
begin
  o := TObject.Create;
  defer o.Free;
  WriteLn(o.ClassName);
end;
begin
  Work;
end.
