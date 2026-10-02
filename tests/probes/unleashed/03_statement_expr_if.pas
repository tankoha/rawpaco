{$mode unleashed}
program StmtExprIf;
// modeswitch statementexpressions: if を式として使う
var
  size: Integer;
begin
  size := 2048;
  var kind := if size > 1024 then 'big' else 'small';
  WriteLn(kind);
end.
