unit CleanupAndReraise;

// 誤検知してはいけない: `try ... except <後始末>; Raise; end;` は
// 「失敗したら後始末して呼び出し元へ投げ直す」というPascalの定型であり、
// try-finallyと同様にエラー処理そのものではない。これを「保護されている」
// と数えると、素直に同じAPIを呼んでいる他の箇所が軒並み誤検知になる
// (fpc-sourceのfpsqlparser.pasで実際に12件出た)。
//
// 補足: tree-sitter-pascal v0.10.2は引数なしの`Raise;`を構文として
// 受け付けずERRORノードにするが、tryの構造自体は保たれるため判定は効く。

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

function ParseGuarded(const AText: string): Integer;
function ParsePlain(const AText: string): Integer;

implementation

function ParseGuarded(const AText: string): Integer;
var
  Buffer: TStringList;
begin
  Buffer := TStringList.Create;
  try
    Buffer.Add(AText);
    Result := StrToInt(Buffer[0]);
  except
    FreeAndNil(Buffer);
    Raise;
  end;
  Buffer.Free;
end;

function ParsePlain(const AText: string): Integer;
begin
  Result := StrToInt(AText);
end;

end.
