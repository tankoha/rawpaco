program call_ellipsis;
begin
  Foo(1);            // match
  Foo(1, 2, 3);      // match
  X := Foo(A) + 1;   // match: call inside an expression
  Foo();             // no match: $X needs one argument
  Bar(1);            // no match: other function
end.
