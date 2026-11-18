program parenless_method;
begin
  X.Free;          // match
  A.B.Free;        // match: $X binds the qualified expression
  X.Free();        // match
  Y := X.Free;     // no match: expression position
  X.Destroy;       // no match: other method
end.
