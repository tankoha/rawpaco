unit dotted_unit_unknown_member;
{$mode objfpc}{$H+}
// ドット付き（名前空間付き）ユニット名で修飾された参照。lhs 自体が exprDot に
// なるため、以前は判定Aが丸ごとスキップしていた。
interface
uses
  SysUtils, Generics.Collections;
implementation
procedure P;
begin
  WriteLn(Generics.Collections.NoSuchFunction(1));
end;
end.
