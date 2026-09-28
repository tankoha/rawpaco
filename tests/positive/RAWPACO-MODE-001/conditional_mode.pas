// モード指令が条件コンパイル内にある場合、どの枝が有効かは構成次第。
unit conditional_mode;
{$ifdef FPC}
  {$mode objfpc}{$H+}
{$endif}
interface
var
  Name: string;
implementation
end.
