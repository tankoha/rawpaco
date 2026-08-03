program MultipleHandlersOneEmpty;

{$mode objfpc}{$H+}

uses
  SysUtils;

begin
  try
    WriteLn('work');
  except
    on EFirst: EConvertError do
      WriteLn('conversion problem: ', EFirst.Message);
    on ESecond: Exception do
      ;
  end;
end.
