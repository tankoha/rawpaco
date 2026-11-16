program error_skip;
begin
  A := 1 +;                 // syntax error in this statement only
  B := TStringList.Create;  // match: the error in the sibling does not hide it
end.
