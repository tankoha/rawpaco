unit lowercase_prefix;

{$mode objfpc}{$H+}

// 接頭辞の照合は大文字小文字を区別する。`T` を要求している以上 `tFoo` は違反。
// FPC のコードには `fBuffer` のような小文字始まりも実在するが、それを許すかは
// プロジェクトの選択なので設定ファイル側で `["F", "f"]` と書いてもらう。

interface

type
  tLowerClass = class
  private
    fValue: Integer;
  end;

implementation

end.
