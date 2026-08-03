unit real_rtl_usage;

{$mode objfpc}{$H+}

// 実在する RTL/FCL API だけを使った、実際に fpc でコンパイルが通るコード。
// 修飾あり・修飾なし・クラスメソッド・inherited・組み込み手続きの
// いずれも誤検知してはならない。

interface

uses
  Classes, SysUtils, StrUtils, Math, DateUtils;

type
  TCounter = class(TStringList)
  private
    FTotal: Integer;
  public
    constructor Create; reintroduce;
    procedure Clear; override;
    function Describe: string;
  end;

implementation

constructor TCounter.Create;
begin
  inherited Create;
  FTotal := 0;
end;

procedure TCounter.Clear;
begin
  inherited Clear;
  FTotal := 0;
end;

function TCounter.Describe: string;
var
  I: Integer;
begin
  Inc(FTotal, Count);
  Result := '';
  for I := 0 to Count - 1 do
    Result := Result + IfThen(I > 0, ', ', '') + Trim(Strings[I]);
  Result := Format('%s (%d, max=%d, %s)',
    [Result, FTotal, Math.Max(FTotal, 1), DateToStr(Now)]);
  SetLength(Result, Length(Result));
end;

end.
