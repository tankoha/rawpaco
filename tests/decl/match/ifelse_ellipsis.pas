program P;
begin
  // 一致する: else のある if（本体は式の文・block・代入のどれでもよい）
  if Assigned(A) then
    X
  else
    Y;
  if Assigned(B) then begin
    X;
  end else
    Z := 1;
  // 一致しない: else が無い、条件が違う
  if Assigned(C) then
    X;
  if Ready(D) then
    X
  else
    Y;
end.
