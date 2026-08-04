unit TryFinallyCleanup;

// 誤検知してはいけない: Pascalで最も定型的な「オープンしてからtry-finallyで
// 確実に閉じる」書き方。finallyは例外を捕捉しないので、これらの手続きは
// どこも「try-exceptで保護されている」状態にはならず、混在も起きない。
// finally節の中身を「未保護」に数えてしまうとこのパターンが毎回誤検知に
// なるため、finally/except節の中身は保護・未保護のどちらにも数えない。

{$mode objfpc}{$H+}

interface

procedure WriteReport(const AFileName: string);
procedure WriteSummary(const AFileName: string);

implementation

procedure WriteReport(const AFileName: string);
var
  F: TextFile;
begin
  AssignFile(F, AFileName);
  Rewrite(F);
  try
    WriteLn(F, 'report');
  finally
    CloseFile(F);
  end;
end;

procedure WriteSummary(const AFileName: string);
var
  F: TextFile;
begin
  AssignFile(F, AFileName);
  Rewrite(F);
  try
    WriteLn(F, 'summary');
  finally
    CloseFile(F);
  end;
end;

end.
