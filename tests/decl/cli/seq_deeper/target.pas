procedure Direct;
begin
  A := TFoo.Create;
  A.Free;
end;

procedure Nested;
begin
  B := TFoo.Create;
  try
    B.Add(1);
  finally
    B.Free;
  end;
end;

procedure Leaks;
begin
  C := TFoo.Create;
  C.Add(1);
end;
