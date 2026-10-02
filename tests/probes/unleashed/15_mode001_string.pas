{$mode unleashed}
program Mode001String;
// ルール挙動の確認: {$mode unleashed} が $H をどう扱うと見なされるか
// (RAWPACO-MODE-001 は {$mode} が $H を既定値に戻すと見なしている)
var
  s: string;
begin
  s := 'x';
  WriteLn(s);
end.
