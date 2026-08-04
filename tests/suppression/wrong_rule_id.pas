program WrongRuleId;

{$mode objfpc}{$H+}

// 別のRuleIdを指定した抑制コメントは無関係なので、RAWPACO-DEFENSE-001は
// 抑制されず通常どおり検知される(誤って何でも抑制してしまわないことの確認)。
begin
  try
    WriteLn('work');
  except // rawpaco:ignore RAWPACO-SEC-001
  end;
end.
