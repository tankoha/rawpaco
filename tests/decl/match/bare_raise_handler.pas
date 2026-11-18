program bare_raise_handler;
begin
  try
    DoWork;
  except
    raise;
  end;                                  // match: the handler only re-raises
  try
    DoWork;
  except
    Log;
    raise;
  end;                                  // no match: the handler does more
  try
    DoWork;
  except
    on E: Exception do raise;
  end;                                  // no match: an exception handler
  try
    DoWork;
  except
    raise Exception.Create('x');
  end;                                  // no match: raises a new exception
  try
    DoWork;
  except
  end;                                  // no match: empty handler
  try
    A := 1 +;
  except
    raise;
  end;                                  // no match: a real syntax error inside
end.
