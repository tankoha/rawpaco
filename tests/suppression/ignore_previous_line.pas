program IgnorePreviousLine;

{$mode objfpc}{$H+}

// RAWPACO-DEFENSE-001が本来検知する空exceptハンドラを、対象行の直前行に
// 付けた抑制コメントで黙らせるケース(設計書4節: 対象行または直前行)。
begin
  try
    WriteLn('work');
    // rawpaco:ignore RAWPACO-DEFENSE-001
  except
  end;
end.
