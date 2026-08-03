unit unknown_unit_disables_check;

{$mode objfpc}{$H+}

// uses に rawpaco から見て未知のユニット（サードパーティ、LCL 等）が
// 1つでもあれば、修飾なしの名前はそこに定義されているかもしれないので
// 判定Bを丸ごと無効にする。

interface

uses
  SysUtils, MyThirdPartyLib;

procedure Run;

implementation

procedure Run;
begin
  SomethingFromTheThirdPartyLib(42);
end;

end.
