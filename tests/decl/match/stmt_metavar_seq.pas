program P;
begin
  // 一致する: 代入・block・式の文が Foo の直後に来る
  Foo;
  G := 2;
  Foo;
  begin
    Bar;
  end;
  Foo;
  Baz(1);
  // 一致しない: 条件コンパイル指令をまたぐ、Foo が最後の文
  Foo;
  {$ifdef X}
  H;
  {$endif}
  Foo;
end.
