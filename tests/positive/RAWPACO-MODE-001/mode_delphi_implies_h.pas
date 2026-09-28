// delphi モードは $H+ を含意するため {$H+} を書かなくても AnsiString。
unit mode_delphi_implies_h;
{$mode delphi}
interface
function Describe: string;
implementation
function Describe: string;
begin
  Result := '';
end;
end.
