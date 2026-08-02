program rawpaco;

{$mode objfpc}{$H+}

uses
  SysUtils;

const
  VersionString = '0.0.1-dev';

begin
  WriteLn('rawpaco ', VersionString, ' - FPC/Lazarus Pascal lint tool (tree-sitter-pascal based)');
  WriteLn('status: bootstrap, no lint rules implemented yet');
end.
