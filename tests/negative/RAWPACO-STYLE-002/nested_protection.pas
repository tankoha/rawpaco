unit NestedProtection;

// 検知されるべき: 内側のtry-finallyは単体では保護にならないが、外側の
// try-exceptに包まれているため CloseFile は「保護されている」に数えられる。
// 一方 Unsafe 側の同じ手続き呼び出しは完全に素通しになっている。

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

procedure ReadSafely(const AFileName: string);
procedure WriteUnsafely(const AFileName: string);

implementation

procedure ReadSafely(const AFileName: string);
var
  F: TextFile;
  Line: string;
begin
  try
    AssignFile(F, AFileName);
    Reset(F);
    try
      ReadLn(F, Line);
      WriteLn(Line);
    finally
      CloseFile(F);
    end;
  except
    on E: EInOutError do
      WriteLn('io error: ', E.Message);
  end;
end;

procedure WriteUnsafely(const AFileName: string);
var
  F: TextFile;
begin
  AssignFile(F, AFileName);
  Rewrite(F);
  WriteLn(F, 'x');
  CloseFile(F);
end;

end.
