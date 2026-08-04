unit OwnConversionWithoutSysutils;

// 誤検知してはいけない: SysUtilsをusesしていないファイルでは、
// StrToInt等のSysUtils由来の名前は監視対象にしない(このファイルの
// StrToIntは自前で宣言したまったく別の関数)。usesによる絞り込みが
// 効いていることを確認するサンプル。

{$mode objfpc}{$H+}

interface

function StrToInt(const AText: string): Integer;
function ParseGuarded(const AText: string): Integer;
function ParsePlain(const AText: string): Integer;

implementation

function StrToInt(const AText: string): Integer;
begin
  Result := Length(AText);
end;

function ParseGuarded(const AText: string): Integer;
begin
  try
    Result := StrToInt(AText);
  except
    Result := -1;
  end;
end;

function ParsePlain(const AText: string): Integer;
begin
  Result := StrToInt(AText);
end;

end.
