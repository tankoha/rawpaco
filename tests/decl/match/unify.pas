program unify;
var I, J: Integer;
begin
  I := I + 1;      // match
  i := (I) + 1;    // match: case and parentheses are ignored
  I := J + 1;      // no match: different variable
  I := I + 2;      // no match: different literal
end.
