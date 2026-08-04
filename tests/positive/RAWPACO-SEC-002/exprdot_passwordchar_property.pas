program ExprDotPasswordCharNotSecret;

{$mode objfpc}{$H+}

type
  TEdit = class
    PasswordChar: char;
  end;

var
  Edit1: TEdit;
begin
  Edit1 := TEdit.Create;
  // PasswordChar is a display-masking character (a common Lazarus/Delphi
  // TCustomEdit property), not a secret value; the identifier merely
  // contains "Password" as a prefix, not as its trailing word.
  Edit1.PasswordChar := '*';
  WriteLn('configured');
end.
