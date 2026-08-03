program EmptyOnHandler;

{$mode objfpc}{$H+}

uses
  SysUtils;

begin
  try
    WriteLn('work');
  except
    on E: Exception do
      ;
  end;
end.
