procedure P;
begin
  Log('a', Value);
  Log('skip', Other);
  Log('b',
      Multi + Line);
  Foo();
  Foo(1, 2);
end;
