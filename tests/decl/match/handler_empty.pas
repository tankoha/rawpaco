program handler_empty;
begin
  try
    DoWork;
  except
    on E: Exception do
      ;                                 // match: empty body
  end;
  try
    DoWork;
  except
    on A: EConvertError do
      Log(A.Message);                   // no match: the handler does something
    on B: Exception do
      ;                                 // match: one empty handler among several
  end;
  try
    DoWork;
  except
    on C: Exception do
      raise;                            // no match: re-raises (the bare raise is an ERROR node)
  end;
  try
    DoWork;
  except
    on Exception do
      ;                                 // no match: the pattern requires a variable
  end;
end.
