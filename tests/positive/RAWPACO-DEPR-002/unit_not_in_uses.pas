unit unit_not_in_uses;

// SysUtils を uses していないファイルでは、同名の識別子が現れても
// SysUtils のシンボルを指しているとは限らない（ここでは MyLocale という
// rawpaco から見て未知のユニット由来）。uses に無いユニットは見ない。

interface

uses
  MyLocale;

procedure Configure;

implementation

procedure Configure;
begin
  DecimalSeparator := '.';
  ShortDateFormat := 'yyyy-mm-dd';
end;

end.
