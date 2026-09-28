unit unknown_call_with_vendor_unit;
{$mode objfpc}{$H+}
// uses に載る vendorns.extra は data/vendor-*-symbols.txt 側にしか無い。
// これが既知ユニットとして読めていれば判定Bの門番を通り、実在しない呼び出しが
// 報告される。読めていなければ「未知のユニットがある」ので判定Bは無効になり
// 何も報告されない。
interface
uses
  SysUtils, vendorns.extra;
implementation
procedure P;
begin
  ThisCallDoesNotExist(1);
end;
end.
