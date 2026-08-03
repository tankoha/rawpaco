unit FPCSymbols;

{$mode objfpc}{$H+}

// data/fpc-rtl-symbols.txt（FPC の RTL/FCL シンボル一覧）のローダ。
// RAWPACO-DEPR-002 / RAWPACO-HALLUC-001 が使う。
//
// なぜ静的データファイルなのか（CLAUDE.mdルール8。詳細な理由は
// tools/gen_fpc_symbols.sh 冒頭のコメントにも記載）:
// lint 実行時に fpc-source や .ppu を読みに行く方式は、(1) Windows CI の
// choco 版 FPC に fpc-source が同梱されている保証がなく、(2) .ppu の内容が
// ターゲット OS/CPU ごとに変わるため同じソースへの lint 結果が環境で変わって
// しまう。tree-sitter-pascal をバージョン固定して vendoring しているのと同じ
// 発想で、生成済みの一覧をリポジトリにコミットして使う。
//
// なぜ独自のテキスト形式で JSON ではないのか:
// JSON にすると fcl-json（fpjson/jsonparser）への依存が増える。Windows CI では
// 基本 RTL 以外のユニット検索パスで繰り返し問題が起きており（HANDOFF.md 参照）、
// 依存を増やさない方が安全と判断した。行頭1文字のタグ + タブ区切りなら
// SysUtils だけで読める。
//
// ロードしたデータは「全ファイル共通の読み取り専用データ」であり、ファイル単位の
// 一時状態ではないため、ルールインスタンスをまたいで共有・キャッシュしてよい。

interface

uses
  SysUtils;

type
  TFPCSymbolInfo = record
    Found: Boolean;
    Exported: Boolean;      // U ブロック直下の G 行（ユニットレベルの公開シンボル）
    IsDeprecated: Boolean;
    DeprecationHint: string;
  end;

// データファイルが見つかり、1ユニット以上読み込めたか。
// 見つからない場合、依存するルールは何も報告しない（CLAUDE.mdルール5）。
function FPCSymbolsAvailable: Boolean;

// data/fpc-rtl-symbols.txt の探索結果のパス（診断メッセージ用。未発見なら空）。
function FPCSymbolsDataFile: string;

function IsKnownFPCUnit(const UnitName: string): Boolean;

// strict = 公開シンボル一覧が網羅的とみなせるユニット。
// loose = プラットフォーム別 include で公開部が組み立てられており網羅性を
// 保証できないユニット（system 等）。「知らない名前だから存在しない」という
// 推論はこのユニットに対しては行ってはいけない。
function IsStrictFPCUnit(const UnitName: string): Boolean;

// UnitName 内の Name を引く。UnitName が未知なら Found=False。
function LookupFPCSymbol(const UnitName, Name: string): TFPCSymbolInfo;

implementation

uses
  Classes, Generics.Collections;

type
  TSymbolMap = specialize TDictionary<string, TFPCSymbolInfo>;

  TUnitEntry = class
    IsStrict: Boolean;
    Symbols: TSymbolMap;
    constructor Create;
    destructor Destroy; override;
  end;

  TUnitMap = specialize TDictionary<string, TUnitEntry>;

var
  GUnits: TUnitMap = nil;
  GLoaded: Boolean = False;
  GDataFile: string = '';

constructor TUnitEntry.Create;
begin
  inherited Create;
  Symbols := TSymbolMap.Create;
end;

destructor TUnitEntry.Destroy;
begin
  Symbols.Free;
  inherited Destroy;
end;

function FindDataFile: string;
var
  Candidates: TStringArray;
  ExeDir, EnvDir, Candidate: string;
  I: Integer;
begin
  Result := '';
  ExeDir := ExtractFilePath(ExpandFileName(ParamStr(0)));
  EnvDir := GetEnvironmentVariable('RAWPACO_DATA_DIR');

  // 探索順の理由: 明示指定(環境変数) > 配布時の想定レイアウト(exeと同階層のdata/)
  // > 開発時のレイアウト(src/rawpaco に対する ../data/) > カレントディレクトリ。
  Candidates := TStringArray.Create(
    '',                                        // 環境変数用のプレースホルダ
    ExeDir + 'data' + DirectorySeparator,
    ExeDir + '..' + DirectorySeparator + 'data' + DirectorySeparator,
    'data' + DirectorySeparator
  );
  if EnvDir <> '' then
    Candidates[0] := IncludeTrailingPathDelimiter(EnvDir);

  for I := 0 to High(Candidates) do
  begin
    if Candidates[I] = '' then Continue;
    Candidate := Candidates[I] + 'fpc-rtl-symbols.txt';
    if FileExists(Candidate) then
      Exit(Candidate);
  end;
end;

procedure ParseLine(const Line: string; var CurrentUnit: TUnitEntry);
var
  Tab1, Tab2, Tab3: Integer;
  Tag, F2, F3: string;
  Info: TFPCSymbolInfo;
  Key: string;

  // タブ区切りの n 番目の位置を返す素朴なヘルパ（SplitStringは
  // 空フィールドの扱いを毎回確認する必要があるので使わない）。
  function NextTab(StartAt: Integer): Integer;
  var
    P: Integer;
  begin
    Result := 0;
    for P := StartAt to Length(Line) do
      if Line[P] = #9 then
        Exit(P);
  end;

begin
  if (Line = '') or (Line[1] = '#') then Exit;

  Tab1 := NextTab(1);
  if Tab1 = 0 then Exit;
  Tag := Copy(Line, 1, Tab1 - 1);

  Tab2 := NextTab(Tab1 + 1);
  if Tab2 = 0 then
    F2 := Copy(Line, Tab1 + 1, Length(Line))
  else
    F2 := Copy(Line, Tab1 + 1, Tab2 - Tab1 - 1);

  if Tag = 'U' then
  begin
    F3 := '';
    if Tab2 > 0 then F3 := Copy(Line, Tab2 + 1, Length(Line));
    CurrentUnit := TUnitEntry.Create;
    CurrentUnit.IsStrict := (F3 = 'strict');
    GUnits.AddOrSetValue(UpperCase(F2), CurrentUnit);
    Exit;
  end;

  if CurrentUnit = nil then Exit;

  Key := UpperCase(F2);
  // 同名が G と M の両方に現れることはない（生成側で排除済み）が、
  // 万一重複しても先勝ちにして G を潰さないようにする。
  if CurrentUnit.Symbols.ContainsKey(Key) then Exit;

  Info.Found := True;
  Info.IsDeprecated := False;
  Info.DeprecationHint := '';

  if Tag = 'G' then
  begin
    Info.Exported := True;
    if Tab2 > 0 then
    begin
      Tab3 := NextTab(Tab2 + 1);
      if Tab3 = 0 then
        F3 := Copy(Line, Tab2 + 1, Length(Line))
      else
      begin
        F3 := Copy(Line, Tab2 + 1, Tab3 - Tab2 - 1);
        Info.DeprecationHint := Copy(Line, Tab3 + 1, Length(Line));
      end;
      Info.IsDeprecated := (F3 = 'D');
    end;
  end
  else if Tag = 'M' then
    Info.Exported := False
  else
    Exit;

  CurrentUnit.Symbols.Add(Key, Info);
end;

procedure EnsureLoaded;
var
  Lines: TStringList;
  CurrentUnit: TUnitEntry;
  I: Integer;
begin
  if GLoaded then Exit;
  GLoaded := True;
  GUnits := TUnitMap.Create;

  GDataFile := FindDataFile;
  if GDataFile = '' then Exit;

  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(GDataFile);
    except
      // 読めなければルールを黙って無効化する（CLAUDE.mdルール5: 疑わしきは見逃す）。
      // 例外の種類で挙動を変えないので on 節は書かない。
      GDataFile := '';
      Exit;
    end;
    CurrentUnit := nil;
    for I := 0 to Lines.Count - 1 do
      ParseLine(Lines[I], CurrentUnit);
  finally
    Lines.Free;
  end;
end;

function FPCSymbolsAvailable: Boolean;
begin
  EnsureLoaded;
  Result := (GUnits <> nil) and (GUnits.Count > 0);
end;

function FPCSymbolsDataFile: string;
begin
  EnsureLoaded;
  Result := GDataFile;
end;

function IsKnownFPCUnit(const UnitName: string): Boolean;
begin
  EnsureLoaded;
  Result := (GUnits <> nil) and GUnits.ContainsKey(UpperCase(UnitName));
end;

function IsStrictFPCUnit(const UnitName: string): Boolean;
var
  Entry: TUnitEntry;
begin
  EnsureLoaded;
  Result := (GUnits <> nil) and GUnits.TryGetValue(UpperCase(UnitName), Entry) and Entry.IsStrict;
end;

function LookupFPCSymbol(const UnitName, Name: string): TFPCSymbolInfo;
var
  Entry: TUnitEntry;
begin
  Result.Found := False;
  Result.Exported := False;
  Result.IsDeprecated := False;
  Result.DeprecationHint := '';
  EnsureLoaded;
  if GUnits = nil then Exit;
  if not GUnits.TryGetValue(UpperCase(UnitName), Entry) then Exit;
  if not Entry.Symbols.TryGetValue(UpperCase(Name), Result) then
  begin
    Result.Found := False;
    Result.Exported := False;
    Result.IsDeprecated := False;
    Result.DeprecationHint := '';
  end;
end;

procedure FreeUnits;
var
  Entry: TUnitEntry;
begin
  if GUnits = nil then Exit;
  // TDictionary は value 側のオブジェクトを自動解放しない（RuleRegistry と同じ）。
  for Entry in GUnits.Values do
    Entry.Free;
  GUnits.Free;
  GUnits := nil;
end;

finalization
  FreeUnits;

end.
