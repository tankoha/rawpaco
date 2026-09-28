// {$H+} を {$mode} より前に置くと mode 指令が $H を既定値に戻すため無効。
{$H+}
{$mode objfpc}
program h_before_mode;
var
  S: string;
begin
  S := '';
end.
