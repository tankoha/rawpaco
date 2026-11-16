program escaped_ident;
begin
  Foo(&begin);  // match
  Foo(&BEGIN);  // match: case-insensitive
  Foo(beginx);  // no match
end.
