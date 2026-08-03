unit qualified_reference;

// ユニット名で修飾した参照 `SysUtils.DecimalSeparator` も検知対象。
// lhs が uses に現れるユニット名なので、レコードのフィールドアクセスと
// 区別できる。

interface

uses
  SysUtils;

function Sep: Char;

implementation

function Sep: Char;
begin
  Result := SysUtils.DecimalSeparator;
end;

end.
