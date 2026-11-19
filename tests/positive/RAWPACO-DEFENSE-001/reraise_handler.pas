program ReraiseHandler;

{$mode objfpc}{$H+}

uses
  SysUtils;

// A handler whose body is a bare `raise;` re-raises the exception, so it is not
// swallowed. tree-sitter-pascal parses the bare `raise;` as an ERROR node before
// the handler's `;` body, which used to look like an empty handler.
begin
  try
    WriteLn('work');
  except
    on E: EConvertError do
      raise;
    on Exception do
      raise;
  end;
end.
