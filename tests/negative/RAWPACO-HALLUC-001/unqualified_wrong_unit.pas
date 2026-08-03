unit unqualified_wrong_unit;

{$mode objfpc}{$H+}

// 判定B: SplitString は StrUtils にあり SysUtils には無い。
// uses が全て既知ユニットなので、ファイル内宣言にも既知ユニットにも
// 無い名前は実在しないと判定できる。

interface

uses
  SysUtils, Classes;

function FirstPart(const S: string): string;

implementation

function FirstPart(const S: string): string;
begin
  Result := SplitString(S, ',')[0];
end;

end.
