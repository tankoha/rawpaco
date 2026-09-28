unit record_member_not_a_unit;

{$mode objfpc}{$H+}

// `Foo.Bar` の lhs がユニット名でない場合（レコード・クラス・変数）は、
// 型解決なしに rhs の妥当性を判断できないので何も言わない。
// ここでは変数 Math が Math ユニット名と衝突しているが、宣言が
// ファイル内にあるのでユニット参照とはみなさない。

interface

uses
  Classes;

procedure Run;

implementation

type
  TVec = record
    X, Y: Double;
  end;

var
  Math: TVec;

procedure Run;
var
  L: TStringList;
begin
  Math.X := 1.0;
  // try..finally で囲んでいるのは RAWPACO-MEM-002 を発火させないため
  // (このフィクスチャの目的は「Math.X をユニット参照と誤認しないこと」の確認)。
  L := TStringList.Create;
  try
    L.Sorted := True;
  finally
    L.Free;
  end;
end;

end.
