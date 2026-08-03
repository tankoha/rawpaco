unit include_directive_disables_check;

{$mode objfpc}{$H+}

// `{$i}` で取り込まれる宣言は構文木に現れないため、「ファイル内で
// 宣言されていない」という判定が成立しない。判定Bを無効にする。

interface

uses
  SysUtils;

{$i helpers.inc}

procedure Run;

implementation

procedure Run;
begin
  HelperDeclaredInTheIncludeFile(1);
end;

end.
