unit conventional_names;

{$mode objfpc}{$H+}

// 既定の命名規則に従ったコード。例外クラスの `E` 接頭辞、Lazarus で一般的な
// `TfrmMain`（接頭辞の直後が小文字）も許容されること。

interface

uses
  SysUtils;

type
  TWidget = class
  private
    FName: string;
  protected
    FOwnerWidget: TWidget;
  public
    Tag: Integer;
    property Name: string read FName write FName;
  end;

  TfrmMain = class(TWidget)
  end;

  EWidgetError = class(Exception);

  IWidgetVisitor = interface
    procedure Visit(AWidget: TWidget);
  end;

  TWidgetKind = (wkButton, wkLabel);

  TWidgetRec = record
    Kind: TWidgetKind;
  end;

  PWidgetRec = ^TWidgetRec;

  TWidgetHelper = class helper for TWidget
    function Describe: string;
  end;

implementation

function TWidgetHelper.Describe: string;
begin
  Result := Name;
end;

end.
