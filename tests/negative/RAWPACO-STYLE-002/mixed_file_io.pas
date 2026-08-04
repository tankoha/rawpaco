unit MixedFileIo;

// 検知されるべき: 同じファイルI/O手続き(AssignFile/CloseFile)が、
// 片方の手続きではtry-exceptで保護され、もう片方では素通しになっている。

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

procedure LoadConfig(const AFileName: string);
procedure SaveConfig(const AFileName: string);

implementation

procedure LoadConfig(const AFileName: string);
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
      WriteLn('failed to load: ', E.Message);
  end;
end;

procedure SaveConfig(const AFileName: string);
var
  F: TextFile;
begin
  AssignFile(F, AFileName);
  Rewrite(F);
  WriteLn(F, 'ok');
  CloseFile(F);
end;

end.
