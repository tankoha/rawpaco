// ビルド構成でモードを選ぶ書き方。同時に2つが有効になるわけではない。
unit conditional_mode_branches;
{$ifdef FPC}
  {$mode objfpc}{$H+}
{$else}
  {$mode delphi}
{$endif}
interface
implementation
end.
