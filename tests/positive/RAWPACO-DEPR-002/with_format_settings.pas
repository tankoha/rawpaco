unit with_format_settings;

// `with レコード do` の中では裸の識別子がレコードのフィールドを指す。
// 型解決ができないので区別がつかず、with の本体は走査しない
// （FPC のソースツリー全体に当てた際、この書き方が誤検知の最大要因だった）。

interface

uses
  SysUtils;

procedure Configure;

implementation

procedure Configure;
var
  Fs: TFormatSettings;
begin
  Fs := DefaultFormatSettings;
  with Fs do
  begin
    DecimalSeparator := '.';
    ThousandSeparator := ',';
    ShortDateFormat := 'yyyy-mm-dd';
  end;
end;

end.
