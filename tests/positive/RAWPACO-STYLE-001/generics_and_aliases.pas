unit generics_and_aliases;

{$mode objfpc}{$H+}

// 対象外であることを確認するもの:
//   - ジェネリック型の型引数（`T` / `TKey` / `TValue`。型名ではないので見ない。
//     型名側は genericTpl の entity である TBox / TPairMap を見る）
//   - 型別名・手続き型・配列型・集合型・class of（既定カテゴリに含めない。
//     RTL 自身が RawByteString のように接頭辞なしの別名を多用しているため）

interface

type
  generic TBox<T> = class
  private
    FItem: T;
  end;

  generic TPairMap<TKey, TValue> = class
  end;

  MyInteger = Integer;
  CallbackProc = procedure(AValue: Integer);
  IntegerArray = array of Integer;
  ByteSet = set of Byte;
  BoxClass = class of TObject;

implementation

end.
