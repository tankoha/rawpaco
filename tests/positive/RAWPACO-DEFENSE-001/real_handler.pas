program RealHandler;

{$mode objfpc}{$H+}

uses
  SysUtils;

begin
  try
    WriteLn('doing work');
  except
    on E: Exception do
      WriteLn('handled: ', E.Message);
  end;
end.
