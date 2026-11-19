program TestPatLexer;

{$mode objfpc}{$H+}

uses
  SysUtils, PatLexer;

const
  MsgE1 = '`$...` must be followed by a metavariable name of uppercase letters, digits and underscores';
  MsgE3 = '`<... ...>` (deep expression) is not supported yet';
  MsgE4 = 'a run of four or more dots is not a valid pattern';

var
  Failures: Integer;

function JoinArr(const A: TStringArray): string;
var
  I: Integer;
  S: string;
begin
  S := '';
  for I := 0 to Length(A) - 1 do
  begin
    if I > 0 then
      S := S + '|';
    S := S + A[I];
  end;
  Result := S;
end;

procedure Check(const Name, Src: string; Hex: Boolean; WantOk: Boolean;
  const WantText, WantMsg: string; WantLine, WantCol: Integer;
  const WantMetaVars, WantEllipses, WantWarnings: string);
var
  Opts: TPatLexOptions;
  R: TPatLexResult;
  GotMetaVars, GotEllipses, GotWarnings: string;
  Pass: Boolean;
begin
  Opts := DefaultPatLexOptions;
  Opts.PascalHexDollar := Hex;
  R := PreprocessPattern(Src, Opts);
  GotMetaVars := JoinArr(R.MetaVars);
  GotEllipses := JoinArr(R.MetaVarEllipses);
  GotWarnings := JoinArr(R.Warnings);
  if WantOk then
  begin
    Pass := R.Ok and (R.Text = WantText) and
      (GotMetaVars = WantMetaVars) and
      (GotEllipses = WantEllipses) and
      (GotWarnings = WantWarnings);
  end
  else
  begin
    Pass := (not R.Ok) and (R.ErrorMessage = WantMsg) and
      (R.ErrorLine = WantLine) and (R.ErrorColumn = WantCol) and
      (R.Text = '');
  end;
  if Pass then
    WriteLn('ok:   ', Name)
  else
  begin
    Inc(Failures);
    WriteLn('FAIL: ', Name);
    WriteLn('  Ok:           got=', R.Ok, ' want=', WantOk);
    WriteLn('  Text:         got=', R.Text, ' want=', WantText);
    WriteLn('  ErrorMessage: got=', R.ErrorMessage, ' want=', WantMsg);
    WriteLn('  ErrorLine:Col: got=', R.ErrorLine, ':', R.ErrorColumn, ' want=', WantLine, ':', WantCol);
    WriteLn('  MetaVars:     got=', GotMetaVars, ' want=', WantMetaVars);
    WriteLn('  Ellipses:     got=', GotEllipses, ' want=', WantEllipses);
    WriteLn('  Warnings:     got=', GotWarnings, ' want=', WantWarnings);
  end;
end;

begin
  Failures := 0;

  Check('metavar', 'X := $X;', False, True,
    'X := __rawpaco_mv_X__;', '', 0, 0,
    'X', '', '');

  Check('args ellipsis', 'Foo($X, ...);', False, True,
    'Foo(__rawpaco_mv_X__, __rawpaco_ell__);', '', 0, 0,
    'X', '', '');

  Check('mvell', 'Foo($...ARGS)', False, True,
    'Foo(__rawpaco_mvell_ARGS__)', '', 0, 0,
    '', 'ARGS', '');

  Check('string kept', 'S := ''$X ...'';', False, True,
    'S := ''$X ...'';', '', 0, 0,
    '', '', '');

  Check('escaped quote', 'S := ''it''''s $X'';', False, True,
    'S := ''it''''s $X'';', '', 0, 0,
    '', '', '');

  Check('brace comment', '{ $X ... } $Y', False, True,
    '{ $X ... } __rawpaco_mv_Y__', '', 0, 0,
    'Y', '', '');

  Check('other comments', '(* $X *) // $Z ...' + #10 + '$W', False, True,
    '(* $X *) // $Z ...' + #10 + '__rawpaco_mv_W__', '', 0, 0,
    'W', '', '');

  Check('paren-star open', '(*)$X*)', False, True,
    '(*)$X*)', '', 0, 0,
    '', '', '');

  Check('hex literals', 'A := $0FF + $0ABC + $ff;', False, True,
    'A := $0FF + $0ABC + $ff;', '', 0, 0,
    '', '', '');

  Check('lone dollar', 'X := $;', False, True,
    'X := $;', '', 0, 0,
    '', '', '');

  Check('range', 'for I := 1..10 do', False, True,
    'for I := 1..10 do', '', 0, 0,
    '', '', '');

  Check('member access', '$X.Free', False, True,
    '__rawpaco_mv_X__.Free', '', 0, 0,
    'X', '', '');

  Check('dedup order', '$Y + $X + $Y', False, True,
    '__rawpaco_mv_Y__ + __rawpaco_mv_X__ + __rawpaco_mv_Y__', '', 0, 0,
    'Y|X', '', '');

  Check('underscore name', '$A_B := $X_1', False, True,
    '__rawpaco_mv_A_B__ := __rawpaco_mv_X_1__', '', 0, 0,
    'A_B|X_1', '', '');

  Check('hex option', '$ABC := 1;', True, True,
    '$ABC := 1;', '', 0, 0,
    '', '', '1:1: `$ABC` is kept as a hexadecimal literal (pascal_hex_dollar)');

  Check('ambiguous hex', '$ABC := 1;', False, False,
    '', '`$ABC` is ambiguous: it reads as both a metavariable and a hexadecimal literal; rename it (e.g. `$X`) or write the literal as `$0ABC`', 1, 1,
    '', '', '');

  Check('ambiguous line2', 'begin' + #10 + '  $X := $DEAD;', False, False,
    '', '`$DEAD` is ambiguous: it reads as both a metavariable and a hexadecimal literal; rename it (e.g. `$X`) or write the literal as `$0DEAD`', 2, 9,
    '', '', '');

  Check('four dots', 'X....Y', False, False,
    '', MsgE4, 1, 2,
    '', '', '');

  Check('deep expr', 'if <... $X ...> then', False, False,
    '', MsgE3, 1, 5,
    '', '', '');

  Check('reserved', '__rawpaco_mv_X__ := 1', False, False,
    '', 'identifier `__rawpaco_mv_X__` uses the reserved prefix `__rawpaco_`', 1, 1,
    '', '', '');

  Check('reserved case', 'X := __RAWPACO_y', False, False,
    '', 'identifier `__RAWPACO_y` uses the reserved prefix `__rawpaco_`', 1, 6,
    '', '', '');

  Check('mvell no name', 'Foo($...)', False, False,
    '', MsgE1, 1, 5,
    '', '', '');

  // 行に単独の文の位置の ellipsis には `;` を補う（M2）。
  Check('stmt ellipsis', 'Foo;' + #10 + '  ...' + #10 + 'Bar;', False, True,
    'Foo;' + #10 + '  __rawpaco_ell__;' + #10 + 'Bar;', '', 0, 0,
    '', '', '');

  Check('stmt ellipsis crlf', 'Foo;' + #13#10 + '...' + #13#10 + 'Bar;', False, True,
    'Foo;' + #13#10 + '__rawpaco_ell__;' + #13#10 + 'Bar;', '', 0, 0,
    '', '', '');

  Check('stmt mvell', 'Foo;' + #10 + '$...BODY' + #10, False, True,
    'Foo;' + #10 + '__rawpaco_mvell_BODY__;' + #10, '', 0, 0,
    '', 'BODY', '');

  Check('ellipsis in parens', 'Foo(' + #10 + '  ...' + #10 + ')', False, True,
    'Foo(' + #10 + '  __rawpaco_ell__' + #10 + ')', '', 0, 0,
    '', '', '');

  Check('ellipsis with semicolon', 'Foo;' + #10 + '...;', False, True,
    'Foo;' + #10 + '__rawpaco_ell__;', '', 0, 0,
    '', '', '');

  Check('ellipsis shares line', 'X := ...' + #10, False, True,
    'X := __rawpaco_ell__' + #10, '', 0, 0,
    '', '', '');

  Check('after brackets close', 'A[1];' + #10 + '...', False, True,
    'A[1];' + #10 + '__rawpaco_ell__;', '', 0, 0,
    '', '', '');

  // `else` の直前には補わない（M2 の実測。`;` が if を終わらせるため）。
  Check('before else', 'if A then' + #10 + '  ...' + #10 + 'else' + #10 + '  ...', False, True,
    'if A then' + #10 + '  __rawpaco_ell__' + #10 + 'else' + #10 + '  __rawpaco_ell__;', '', 0, 0,
    '', '', '');

  Check('before else comment', 'if A then' + #10 + '  $...B' + #10 + '  // c' + #10 + '  ELSE X;', False, True,
    'if A then' + #10 + '  __rawpaco_mvell_B__' + #10 + '  // c' + #10 + '  ELSE X;', '', 0, 0,
    '', 'B', '');

  Check('before elsewhere ident', 'Foo;' + #10 + '...' + #10 + 'ElseWhere;', False, True,
    'Foo;' + #10 + '__rawpaco_ell__;' + #10 + 'ElseWhere;', '', 0, 0,
    '', '', '');

  if Failures > 0 then
  begin
    WriteLn('TestPatLexer: ', Failures, ' failure(s)');
    Halt(1);
  end
  else
    WriteLn('TestPatLexer: all 32 cases passed');
end.
