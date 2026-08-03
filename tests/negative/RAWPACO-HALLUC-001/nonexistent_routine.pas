unit nonexistent_routine;

{$mode objfpc}{$H+}

// 判定B: そもそも存在しない名前の呼び出し。

interface

uses
  SysUtils;

procedure Run;

implementation

procedure Run;
begin
  NoSuchProcedureAnywhere(1, 2);
end;

end.
