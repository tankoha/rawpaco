program empty_except;
begin
  try
    DoWork;
  except
  end;                     // match: empty handler
  try
    DoWork;
    DoMore;
  except
    on E: Exception do
      Log(E.Message);
  end;                     // no match: the handler does something
end.
