program IgnoreSameLine;

{$mode objfpc}{$H+}

// RAWPACO-DEFENSE-001が本来検知する空exceptハンドラを、対象行そのものに
// 付けた抑制コメントで黙らせるケース(設計書4節)。
begin
  try
    WriteLn('work');
  except // rawpaco:ignore RAWPACO-DEFENSE-001
  end;
end.
