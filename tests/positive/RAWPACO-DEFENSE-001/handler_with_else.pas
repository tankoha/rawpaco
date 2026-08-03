program HandlerWithElse;

{$mode objfpc}{$H+}

uses
  SysUtils;

begin
  try
    WriteLn('doing work');
  except
    on E: EInOutError do
      WriteLn('io error: ', E.Message);
  else
    WriteLn('unexpected error');
  end;
end.
