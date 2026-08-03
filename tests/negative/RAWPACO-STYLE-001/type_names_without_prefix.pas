unit type_names_without_prefix;

{$mode objfpc}{$H+}

// 既定の命名規則に違反する型名。class/object/record/interface/列挙/ポインタ型の
// それぞれが検知されること。

interface

type
  MyClass = class
  end;

  MyObject = object
  end;

  MyRecord = record
    A: Integer;
  end;

  MyInterface = interface
  end;

  MyEnum = (meOne, meTwo);

  MyPointer = ^Integer;

implementation

end.
