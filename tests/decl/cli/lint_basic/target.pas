program target;
begin
  try
    DoWork;
  except
  end;              // DECL-EMPTY-EXCEPT
  List.Free;        // DECL-FREE (paren-less, statement position)
  Y := List.Free;   // not reported: expression position
end.
