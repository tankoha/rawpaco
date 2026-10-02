{$mode unleashed}
program Mem001AutofreeLocal;
// ルール挙動の確認: autofree 付きで生成した手続きローカル変数を
// RAWPACO-MEM-001 がどう扱うか(Unleashed の意味では解放漏れではない)
uses Classes;
procedure Work;
var
  list: TStringList;
begin
  list := autofree TStringList.Create;
  list.Add('x');
end;
begin
  Work;
end.
