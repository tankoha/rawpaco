procedure T;
var
  I: Integer;
begin
  List.Free;
  Self.Free;
  for I := 1 to 3 do
    WriteLn(I);
  try
    WriteLn('guarded');
  finally
    Obj.Free;
  end;
  Halt(1);
  RunError(2);
  RunError(0);
  if P <> nil then
    Use(P);
  if P <> nil then
    Use(Q);
  Use(R);
  Foo(A, 1);
  Foo(A, 2);
  Foo(B, C, 1);
end;
