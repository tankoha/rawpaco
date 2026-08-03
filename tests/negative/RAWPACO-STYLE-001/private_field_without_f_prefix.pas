unit private_field_without_f_prefix;

{$mode objfpc}{$H+}

// class の private / protected セクションのフィールドは既定で `F` 接頭辞を
// 要求する。`A, B: Integer;` のように1行に複数名がある場合も個別に見ること。

interface

type
  TThing = class
  private
    Name: string;
    Width, Height: Integer;
  protected
    Owner: TObject;
  public
    procedure Reset;
  end;

implementation

procedure TThing.Reset;
begin
  Name := '';
end;

end.
