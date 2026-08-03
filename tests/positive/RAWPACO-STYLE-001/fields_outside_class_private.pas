unit fields_outside_class_private;

{$mode objfpc}{$H+}

// `F` 接頭辞を要求してはいけないフィールド:
//   - record / object のフィールド（`F` の慣習はクラスの非公開フィールドに
//     対するもので、レコードには当てはまらない。RTL の TFormatSettings 等がそう）
//   - class の public / published / 可視性指定なしのフィールド
//   - class var（クラス変数。declField ではない）

interface

type
  TPoint3D = record
    X, Y, Z: Double;
  end;

  TLegacy = object
  private
    Data: Integer;
  end;

  TExposed = class
    ImplicitlyPublished: Integer;
  public
    Counter: Integer;
    Label1: string;
  private
    class var SharedCount: Integer;
  end;

implementation

end.
