program clean;
begin
  try
    DoWork;
  except
    on E: Exception do
      Log(E.Message);
  end;
end.
