program ReraiseHandler;

{$mode objfpc}{$H+}

uses
  SysUtils;

// Re-raising handlers must not be reported: the exception is not swallowed.
// tree-sitter-pascal turns the bare `raise;` into an ERROR node, so the handler's
// body field is only the `;` token; the native RAWPACO-DEFENSE-001 currently
// reports these (a known false positive), the declarative rule does not.
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
