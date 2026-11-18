program TestMsgInterp;

{$mode objfpc}{$H+}

// MsgInterp（宣言的ルールの message の $X 補間）の単体テスト。期待値は実装からではなく
// 仕様（src/Decl/MsgInterp.pas の interface のコメント）から書いている。

uses
  SysUtils, MsgInterp;

var
  Failures: Integer;
  Total: Integer;

procedure CheckEq(const Name, Got, Want: string);
begin
  Inc(Total);
  if Got <> Want then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', Name);
    WriteLn('  want: [', Want, ']');
    WriteLn('  got:  [', Got, ']');
  end;
end;

// 参照の一覧を `名前/省略記号か/位置/長さ` の並びにして比べる。
function RefsToString(const Msg: string): string;
var
  Refs: TMsgVarRefArray;
  I: Integer;
begin
  Result := '';
  Refs := FindMessageMetaVars(Msg);
  for I := 0 to High(Refs) do
  begin
    if I > 0 then
      Result := Result + ' ';
    Result := Result + Format('%s/%s/%d/%d', [Refs[I].Name, BoolToStr(Refs[I].IsEllipsis, 'E', 'V'),
      Refs[I].StartPos, Refs[I].Len]);
  end;
end;

procedure TestFind;
begin
  CheckEq('find: none', RefsToString('no references here'), '');
  CheckEq('find: simple', RefsToString('free $X now'), 'X/V/6/2');
  CheckEq('find: longest name', RefsToString('$XY'), 'XY/V/1/3');
  CheckEq('find: digits and underscore', RefsToString('$OBJ_2.'), 'OBJ_2/V/1/6');
  CheckEq('find: underscore start', RefsToString('$_'), '_/V/1/2');
  CheckEq('find: lowercase stops the name', RefsToString('$Xs'), 'X/V/1/2');
  CheckEq('find: lowercase start is not a reference', RefsToString('$x'), '');
  CheckEq('find: digit start is not a reference', RefsToString('$1'), '');
  CheckEq('find: lone dollar', RefsToString('cost $ and $'), '');
  CheckEq('find: ellipsis', RefsToString('args: $...ARGS'), 'ARGS/E/7/8');
  CheckEq('find: bare ellipsis is not a reference', RefsToString('$... and $..X'), '');
  CheckEq('find: two in a row', RefsToString('$A$B'), 'A/V/1/2 B/V/3/2');
  CheckEq('find: repeated', RefsToString('$X and $X'), 'X/V/1/2 X/V/8/2');
end;

procedure TestKey;
begin
  CheckEq('key: plain', BindingKey('X', False), 'X');
  CheckEq('key: ellipsis', BindingKey('ARGS', True), '...ARGS');
end;

procedure TestInterpolate;
begin
  CheckEq('interp: no refs', InterpolateMessage('plain', ['X'], ['v']), 'plain');
  CheckEq('interp: one', InterpolateMessage('free $X now', ['X'], ['List']), 'free List now');
  CheckEq('interp: repeated', InterpolateMessage('$X = $X', ['X'], ['A.B']), 'A.B = A.B');
  CheckEq('interp: two names', InterpolateMessage('$A then $B', ['A', 'B'], ['1', '2']), '1 then 2');
  CheckEq('interp: unbound stays', InterpolateMessage('$X and $Y', ['X'], ['v']), 'v and $Y');
  CheckEq('interp: $_ stays', InterpolateMessage('$_ is ignored', ['X'], ['v']), '$_ is ignored');
  CheckEq('interp: longer name is not a prefix match', InterpolateMessage('$XY', ['X'], ['v']), '$XY');
  CheckEq('interp: ellipsis', InterpolateMessage('Foo($...ARGS)', ['...ARGS'], ['1, 2']), 'Foo(1, 2)');
  CheckEq('interp: $X does not take a range binding', InterpolateMessage('$ARGS', ['...ARGS'], ['1, 2']), '$ARGS');
  CheckEq('interp: $...X does not take a single binding', InterpolateMessage('$...X', ['X'], ['v']), '$...X');
  CheckEq('interp: empty range', InterpolateMessage('Foo($...ARGS)', ['...ARGS'], ['']), 'Foo()');
  CheckEq('interp: case sensitive keys', InterpolateMessage('$X', ['x'], ['v']), '$X');
  CheckEq('interp: first duplicate key wins', InterpolateMessage('$X', ['X', 'X'], ['first', 'second']), 'first');
  CheckEq('interp: whitespace collapsed', InterpolateMessage('[$X]', ['X'], ['  A' + #13#10 + #9 + '+  B  ']), '[A + B]');
  CheckEq('interp: value with dollar is not re-expanded', InterpolateMessage('$X $Y', ['X', 'Y'], ['$Y', 'y']), '$Y y');
  CheckEq('interp: no keys', InterpolateMessage('$X', [], []), '$X');
end;

begin
  Failures := 0;
  Total := 0;
  TestFind;
  TestKey;
  TestInterpolate;
  if Failures > 0 then
  begin
    WriteLn('TestMsgInterp: ', Failures, ' of ', Total, ' cases FAILED');
    Halt(1);
  end;
  WriteLn('TestMsgInterp: all ', Total, ' cases passed');
end.
