unit ConsistentHandling;

// 誤検知してはいけない: 同じファイルI/O手続きが、どの箇所でも一貫して
// try-exceptで保護されている。

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

procedure LoadPrimary(const AFileName: string);
procedure LoadSecondary(const AFileName: string);

implementation

procedure LoadPrimary(const AFileName: string);
var
  F: TextFile;
  Line: string;
begin
  try
    AssignFile(F, AFileName);
    Reset(F);
    ReadLn(F, Line);
    CloseFile(F);
  except
    on E: Exception do
      WriteLn('primary failed: ', E.Message);
  end;
end;

procedure LoadSecondary(const AFileName: string);
var
  F: TextFile;
  Line: string;
begin
  try
    AssignFile(F, AFileName);
    Reset(F);
    ReadLn(F, Line);
    CloseFile(F);
  except
    on E: Exception do
      WriteLn('secondary failed: ', E.Message);
  end;
end;

end.
