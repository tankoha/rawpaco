unit dotted_unit_real_member;
{$mode objfpc}{$H+}
// ドット付きユニット名で修飾された「実在する」参照は報告してはいけない。
interface
uses
  SysUtils, Generics.Collections;
type
  TIntList = specialize Generics.Collections.TList<Integer>;
implementation
end.
