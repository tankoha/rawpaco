program P;
begin
  // 一致する: 包まれていない文（block・代入・入れ子の if）と、包まれた式の文
  if Assigned(A) then begin
    X;
  end;
  if Assigned(B) then
    Y;
  if Assigned(C) then
    Z := 1;
  if Assigned(D) then
    if E then F;
  // 一致しない: 条件が違う、else がある（ifElse は別の種別）
  if Ready(G) then
    H;
  if Assigned(I) then
    J
  else
    K;
end.
