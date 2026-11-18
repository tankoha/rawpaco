program bare_raise_any;
begin
  try
    DoWork;
  except
    on E: Exception do raise;           // match
  end;
  if Failed then raise;                 // match
  raise E;                              // no match: raises a given exception
end.
