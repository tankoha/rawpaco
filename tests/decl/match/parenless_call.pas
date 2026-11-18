program parenless_call;
begin
  Foo;                       // match: paren-less call in statement position
  if C then Foo else Bar;    // match: the then branch is a statement without ';'
  while C do Foo;            // match
  Foo(1);                    // match
  Y := Foo;                  // no match: in an expression it may be a variable
  Z := Foo + 1;              // no match: same
  FooBar;                    // no match: other name
end.
