unit format_settings_field;

// deprecated なグローバル変数の「正しい置き換え方」。TFormatSettings の
// フィールドアクセスであって RTL のグローバル変数ではないので、
// 決して検知してはならない。

interface

uses
  SysUtils;

function Sep: Char;

implementation

function Sep: Char;
var
  Fs: TFormatSettings;
begin
  Fs := DefaultFormatSettings;
  Fs.DecimalSeparator := '.';
  Fs.ShortDateFormat := 'yyyy-mm-dd';
  Result := Fs.DecimalSeparator;
end;

end.
