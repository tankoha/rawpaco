program NumericAddition;

{$mode objfpc}{$H+}

var
  Price, Tax, Total: Integer;
begin
  Price := 100;
  Tax := 8;
  Total := Price + Tax;
  WriteLn(Total);
end.
