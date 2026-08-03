unit RawpacoConfig;

{$mode objfpc}{$H+}

// rawpaco の設定ファイル（`rawpaco.json`）の読み込み。
// 現時点では RAWPACO-STYLE-001（命名規則）だけが設定を使う。
//
// 形式に JSON を選んだ理由（CLAUDE.mdルール8）:
// 独自のINI風フォーマットを自前パースする案（fcl-json 依存を増やさない）も
// 検討したが、利用者が書くファイルである以上、独自形式より広く知られた形式の
// 方がよいと判断した。fcl-json は FPC 標準同梱パッケージであり、CI 側は
// Linux/Windows とも `-Fu<unitsroot>/*` で全パッケージディレクトリを検索パスに
// 含める方式に統一済みなので、追加の CI 変更なしで解決できる。
//
// 設定ファイルの探索順:
//   1. `--config=<path>` で明示指定されたパス（読めなければエラーで終了する。
//      明示指定を黙って無視するのは事故のもとなので、ここだけは寛容にしない）
//   2. カレントディレクトリから親方向へ `rawpaco.json` を探す
//   3. どこにも無ければ全て既定値
//
// 設定ファイルの例（値は既定値そのもの）:
//
//   {
//     "naming": {
//       "enabled": true,
//       "class":        ["T", "E"],
//       "object":       ["T"],
//       "record":       ["T"],
//       "interface":    ["I"],
//       "enum":         ["T"],
//       "pointer":      ["P"],
//       "privateField": ["F"]
//     }
//   }
//
// 各カテゴリの値には「許可する接頭辞の配列」を書く。`false`・`null`・`[]` の
// いずれかを書くとそのカテゴリのチェックを無効化できる。`"naming"."enabled"` を
// false にすると命名規則チェック全体が無効になる。
//
// 未知のキーはエラーにする。設定ファイルのタイプミスが「黙って何も起きない」に
// なるのが最悪の失敗モードなので、寛容に無視しない。

interface

uses
  SysUtils;

type
  TNamingCategory = (
    ncClass,         // TFoo = class ... end
    ncObject,        // TFoo = object ... end
    ncRecord,        // TFoo = record ... end
    ncInterface,     // IFoo = interface ... end
    ncEnum,          // TFoo = (a, b)
    ncPointer,       // PFoo = ^TFoo
    ncPrivateField   // class の private/protected セクションのフィールド
  );

// 設定を初期化する。ExplicitPath が空なら自動探索する。
// 失敗した場合のみ False を返し、ErrorMsg に理由を入れる。
function InitConfig(const ExplicitPath: string; out ErrorMsg: string): Boolean;

// 実際に読み込んだ設定ファイルのパス（既定値のみなら空文字列）。
function ConfigFilePath: string;

function NamingCheckEnabled: Boolean;
// 当該カテゴリで許可される接頭辞。空配列ならそのカテゴリはチェックしない。
function NamingPrefixes(Category: TNamingCategory): TStringArray;
// 診断メッセージ用の表示名（'class', 'private field' 等）。
function NamingCategoryLabel(Category: TNamingCategory): string;

implementation

uses
  Classes, fpjson, jsonparser;

type
  TCategoryKeys = array[TNamingCategory] of string;

const
  // JSON のキー名。TNamingCategory の並びと1対1に対応させる。
  CCategoryKeys: TCategoryKeys = (
    'class', 'object', 'record', 'interface', 'enum', 'pointer', 'privateField');

  CCategoryLabels: TCategoryKeys = (
    'class', 'object', 'record', 'interface', 'enumeration', 'pointer type',
    'private field');

  CConfigFileName = 'rawpaco.json';

var
  GConfigPath: string = '';
  GNamingEnabled: Boolean = True;
  GPrefixes: array[TNamingCategory] of TStringArray;

// 既定値。docs/CONFIG.md と本ユニット冒頭のコメントに合わせること。
//
// なぜこの範囲だけを既定 on にするか（CLAUDE.mdルール5・8）:
// 型名の `T`、例外クラスの `E`、インターフェースの `I`、ポインタ型の `P`、
// private/protected フィールドの `F` は Delphi・Lazarus/FPC の双方で
// 広く合意されている。一方、引数の `A` 接頭辞・定数の UPPER_CASE・
// グローバル変数の `g` 接頭辞・列挙値の接頭辞はコミュニティで揺れており
// （FPC の RTL 自身が従っていない箇所も多い）、既定で警告すると
// 誤検知同然のノイズになるため既定 off とし、設定ファイルで有効化できる
// 余地も現時点では持たせない（対象ノードを増やす別の作業になる）。
procedure SetDefaults;
begin
  GNamingEnabled := True;
  GPrefixes[ncClass] := TStringArray.Create('T', 'E');
  GPrefixes[ncObject] := TStringArray.Create('T');
  GPrefixes[ncRecord] := TStringArray.Create('T');
  GPrefixes[ncInterface] := TStringArray.Create('I');
  GPrefixes[ncEnum] := TStringArray.Create('T');
  GPrefixes[ncPointer] := TStringArray.Create('P');
  GPrefixes[ncPrivateField] := TStringArray.Create('F');
end;

function ReadFileAsString(const FileName: string): AnsiString;
var
  Stream: TFileStream;
begin
  Result := '';
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

// カレントディレクトリから親方向へ rawpaco.json を探す。
function DiscoverConfigPath: string;
var
  Dir, Parent, Candidate: string;
begin
  Result := '';
  Dir := IncludeTrailingPathDelimiter(ExpandFileName(GetCurrentDir));
  repeat
    Candidate := Dir + CConfigFileName;
    if FileExists(Candidate) then
      Exit(Candidate);
    Parent := ExtractFilePath(ExcludeTrailingPathDelimiter(Dir));
    // ルートに到達すると ExtractFilePath が同じ値を返すので、そこで打ち切る。
    if (Parent = '') or (Parent = Dir) then
      Exit;
    Dir := Parent;
  until False;
end;

// 1カテゴリぶんの値を解釈する。false / null / [] は「無効化」。
function ParseCategory(Value: TJSONData; const Key: string;
  out Prefixes: TStringArray; out ErrorMsg: string): Boolean;
var
  Arr: TJSONArray;
  I: Integer;
  S: string;
begin
  Prefixes := nil;
  ErrorMsg := '';
  Result := True;

  case Value.JSONType of
    jtNull:
      Exit;
    jtBoolean:
      begin
        if Value.AsBoolean then
        begin
          ErrorMsg := Format('"naming"."%s": true is not a valid value; ' +
            'use an array of prefixes (e.g. ["T"]) or false to disable', [Key]);
          Exit(False);
        end;
        Exit;
      end;
    jtString:
      begin
        SetLength(Prefixes, 1);
        Prefixes[0] := Value.AsString;
        Exit;
      end;
    jtArray:
      begin
        Arr := TJSONArray(Value);
        SetLength(Prefixes, Arr.Count);
        for I := 0 to Arr.Count - 1 do
        begin
          if Arr.Items[I].JSONType <> jtString then
          begin
            ErrorMsg := Format('"naming"."%s"[%d]: expected a string prefix', [Key, I]);
            Exit(False);
          end;
          S := Arr.Items[I].AsString;
          if S = '' then
          begin
            ErrorMsg := Format('"naming"."%s"[%d]: prefix must not be empty', [Key, I]);
            Exit(False);
          end;
          Prefixes[I] := S;
        end;
        Exit;
      end;
  end;

  ErrorMsg := Format('"naming"."%s": expected an array of prefixes, a string, ' +
    'false, or null', [Key]);
  Result := False;
end;

function ParseNaming(Obj: TJSONObject; out ErrorMsg: string): Boolean;
var
  I: Integer;
  Key: string;
  Cat: TNamingCategory;
  Known: Boolean;
  Prefixes: TStringArray;
begin
  ErrorMsg := '';
  for I := 0 to Obj.Count - 1 do
  begin
    Key := Obj.Names[I];
    if Key = 'enabled' then
    begin
      if Obj.Items[I].JSONType <> jtBoolean then
      begin
        ErrorMsg := '"naming"."enabled": expected true or false';
        Exit(False);
      end;
      GNamingEnabled := Obj.Items[I].AsBoolean;
      Continue;
    end;

    Known := False;
    for Cat := Low(TNamingCategory) to High(TNamingCategory) do
      if CCategoryKeys[Cat] = Key then
      begin
        if not ParseCategory(Obj.Items[I], Key, Prefixes, ErrorMsg) then
          Exit(False);
        GPrefixes[Cat] := Prefixes;
        Known := True;
        Break;
      end;

    if not Known then
    begin
      ErrorMsg := Format('unknown key "naming"."%s"', [Key]);
      Exit(False);
    end;
  end;
  Result := True;
end;

function ParseConfig(const Source: AnsiString; out ErrorMsg: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  I: Integer;
  Key: string;
begin
  ErrorMsg := '';
  Data := nil;
  try
    try
      Data := GetJSON(Source);
    except
      on E: Exception do
      begin
        ErrorMsg := 'invalid JSON: ' + E.Message;
        Exit(False);
      end;
    end;

    if (Data = nil) or (Data.JSONType <> jtObject) then
    begin
      ErrorMsg := 'the top level must be a JSON object';
      Exit(False);
    end;

    Root := TJSONObject(Data);
    for I := 0 to Root.Count - 1 do
    begin
      Key := Root.Names[I];
      if Key = 'naming' then
      begin
        if Root.Items[I].JSONType <> jtObject then
        begin
          ErrorMsg := '"naming": expected an object';
          Exit(False);
        end;
        if not ParseNaming(TJSONObject(Root.Items[I]), ErrorMsg) then
          Exit(False);
      end
      else
      begin
        ErrorMsg := Format('unknown top level key "%s"', [Key]);
        Exit(False);
      end;
    end;
    Result := True;
  finally
    Data.Free;
  end;
end;

function InitConfig(const ExplicitPath: string; out ErrorMsg: string): Boolean;
var
  Path, Source: string;
begin
  ErrorMsg := '';
  SetDefaults;
  GConfigPath := '';

  if ExplicitPath <> '' then
  begin
    if not FileExists(ExplicitPath) then
    begin
      ErrorMsg := Format('config file not found: %s', [ExplicitPath]);
      Exit(False);
    end;
    Path := ExplicitPath;
  end
  else
  begin
    Path := DiscoverConfigPath;
    if Path = '' then
      Exit(True);
  end;

  try
    Source := ReadFileAsString(Path);
  except
    on E: Exception do
    begin
      ErrorMsg := Format('cannot read config file %s: %s', [Path, E.Message]);
      Exit(False);
    end;
  end;

  if not ParseConfig(Source, ErrorMsg) then
  begin
    ErrorMsg := Format('%s: %s', [Path, ErrorMsg]);
    Exit(False);
  end;

  GConfigPath := Path;
  Result := True;
end;

function ConfigFilePath: string;
begin
  Result := GConfigPath;
end;

function NamingCheckEnabled: Boolean;
begin
  Result := GNamingEnabled;
end;

function NamingPrefixes(Category: TNamingCategory): TStringArray;
begin
  Result := GPrefixes[Category];
end;

function NamingCategoryLabel(Category: TNamingCategory): string;
begin
  Result := CCategoryLabels[Category];
end;

initialization
  // 設定ファイルが読まれないまま参照されても既定値で動くようにしておく
  // （テストや将来の埋め込み利用で InitConfig を呼び忘れた場合の保険）。
  SetDefaults;

end.
