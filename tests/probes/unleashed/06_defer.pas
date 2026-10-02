{$mode unleashed}
program Defer;
// scoped cleanup: defer 文
var
  f: TextFile;
  x: TObject;
begin
  AssignFile(f, 'a.txt');
  Reset(f);
  defer CloseFile(f);
  x := TObject.Create;
  defer x.Free;
  WriteLn('body');
end.
