unit deprecated_global_var;

// SysUtils の DecimalSeparator / ShortDateFormat はグローバル変数として
// deprecated 指定されている（現在は DefaultFormatSettings のフィールドを使う）。

interface

uses
  SysUtils;

procedure Configure;

implementation

procedure Configure;
begin
  DecimalSeparator := '.';
  ShortDateFormat := 'yyyy-mm-dd';
end;

end.
