procedure Direct;
begin
  L := TFoo.Create;
  L.Add(1);
  L.Free;
end;

procedure Adjacent;
begin
  L := TFoo.Create;
  L.Free;
end;

procedure OtherVariable;
begin
  L := TFoo.Create;
  M.Free;
end;

procedure WrongOrder;
begin
  L.Free;
  L := TFoo.Create;
end;

procedure Nested;
begin
  L := TFoo.Create;
  try
    L.Add(1);
  finally
    L.Free;
  end;
end;

procedure SplitByDirective;
begin
  L := TFoo.Create;
  {$IFDEF X}
  L.Free;
  {$ENDIF}
end;

procedure CommentBetween;
begin
  L := TFoo.Create;
  // a comment does not split the sequence
  L.Free;
end;
