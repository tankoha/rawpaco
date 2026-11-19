program ReraiseHandler;

{$mode objfpc}{$H+}

uses
  SysUtils;

// Re-raising handlers must not be reported: the exception is not swallowed.
// tree-sitter-pascal turns the bare `raise;` into an ERROR node, so the handler's
// body field is only the `;` token. Both the native RAWPACO-DEFENSE-001 (fixed on
// 2026-11-19; it used to report these) and the declarative rule report nothing.
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
