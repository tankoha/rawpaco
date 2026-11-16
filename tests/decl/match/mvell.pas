program mvell;
begin
  Foo(1, 2);   // match: $...ARGS = 1, 2
  Foo();       // match: $...ARGS is empty
  Bar(1);      // no match
end.
