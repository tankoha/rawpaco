program parenless_needs_args;
begin
  Foo;             // no match: the pattern requires one argument
  Foo(1);          // match
end.
