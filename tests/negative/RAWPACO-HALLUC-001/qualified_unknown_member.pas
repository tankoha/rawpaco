unit qualified_unknown_member;

{$mode objfpc}{$H+}

// 判定A: `Math.Clamp` は FPC 3.2.2 の Math ユニットには存在しない
// （Delphi 10.3+ にはあり、生成コードが取り違えやすい。FPC では
//  EnsureRange が対応する）。ユニット名で修飾されている以上、
// Math ユニットのシンボルでなければならないので安全に判定できる。

interface

uses
  Math;

function Limit(X: Double): Double;

implementation

function Limit(X: Double): Double;
begin
  Result := Math.Clamp(X, 0.0, 1.0);
end;

end.
