unit QualifiedAndConstantCalls;

// 誤検知してはいけない: 監視対象と同じ綴りでも、
//  - 修飾付き呼び出し (`C.Reset`)
//  - 括弧なし呼び出し (`Reset;`)
//  - 引数が定数リテラルだけの呼び出し (`StrToInt('42')`)
// は対象外。よって「未保護の呼び出し」は1件も残らない。

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TCounter = class
  private
    FValue: Integer;
  public
    procedure Reset;
    procedure Bump(const AText: string);
    property Value: Integer read FValue;
  end;

procedure Demo;

implementation

procedure TCounter.Reset;
begin
  FValue := 0;
end;

procedure TCounter.Bump(const AText: string);
begin
  try
    FValue := FValue + StrToInt(AText);
  except
    on E: EConvertError do
    begin
      WriteLn('bad number: ', E.Message);
      Reset;
    end;
  end;
end;

procedure Demo;
var
  C: TCounter;
begin
  C := TCounter.Create;
  try
    C.Reset;
    C.Bump('7');
    WriteLn(StrToInt('42'));
    WriteLn(C.Value);
  finally
    C.Free;
  end;
end;

end.
