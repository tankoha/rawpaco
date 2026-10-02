{$mode unleashed}
program StmtExprCase;
// modeswitch statementexpressions: case を式として使う
var
  level: Integer;
begin
  level := 1;
  var msg := case level of 0: 'off'; 1: 'warn'; else 'all'; end;
  WriteLn(msg);
end.
