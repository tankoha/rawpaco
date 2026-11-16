program call_any;
begin
  Foo();         // match: the empty argument list has no exprArgs node
  Foo(1, 2);     // match
  Bar(1);        // no match
end.
