program bare_raise_mv;
begin
  if Failed then raise;                 // match
  if Failed then raise E;               // no match: not a bare raise
  if Failed then Exit;                  // no match
end.
