procedure P;
begin
  Before;
  L := TFoo.Create;
  L.Add(1);
  L.Free;
end;

procedure Q;
begin
  Other := 1;
end;
