procedure P;
begin
  Foo;
  Bar;
  Foo;
  Baz;
  Bar;
  repeat
    Foo;
    Bar;
  until Done;
  try
    Qux;
  except
    Foo();
    Bar;
  end;
  if C then
  begin
    Foo;
  end;
  Bar;
end;
