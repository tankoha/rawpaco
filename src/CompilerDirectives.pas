unit CompilerDirectives;

{$mode objfpc}{$H+}

// FPC のコンパイラ指令（`{$...}` / `(*$...*)`）を構文木から収集し、種別・引数・
// 条件コンパイルの深さを付けて返すユニット。RAWPACO-MODE-001 / MODE-002 が使う。
//
// なぜ独立ユニットなのか（CLAUDE.mdルール8）:
// 指令の意味（`$H` と `$LONGSTRINGS` が同義、`{$H+,I-}` のように1つの指令に
// 複数のスイッチが並ぶ、`{$mode}` がモードごとに `$H` の既定値を設定し直す 等）は
// tree-sitter のノード走査とは無関係な FPC 固有の知識なので、ノード走査補助を
// 集めた `ASTHelpers.pas` ではなくこちらに置く（`FPCSymbols.pas` が FPC の
// シンボル知識を担っているのと同じ切り分け）。
//
// ■ tree-sitter-pascal(v0.10.2) の実際の挙動（プローブプログラムで実機確認）
//
// - `{$mode objfpc}` や `{$h+ }`、`{$H+,I-}` はいずれも `pp` ノードになる。
//   `pp` は named ノードなので通常の走査で到達できる。テキストは
//   `ts_node_start_byte`/`end_byte` で切り出すと `{$` と `}` を含む。
// - **`(*$H+*)` という旧形式は `pp` にならず `comment` ノードになる**（文法の穴）。
//   FPC 側はこの形式を正しく指令として解釈する（実測: `{$mode objfpc}(*$H+*)`
//   で `string` が AnsiString になる）ため、`comment` ノードのうち `(*$` で
//   始まるものも指令として扱う必要がある。これを見落とすと「`$H+` が無い」と
//   誤検知する。
// - 逆に **`{$ H+}`（`$` の直後に空白）は FPC 側が指令として認識しない**
//   （実測: `string` は ShortString のまま）。したがって `{$` の直後が
//   そのまま指令名である場合のみ指令として扱う。
//
// ■ 実測した FPC の意味論（実装前に fpc 3.2.2 で確認。CLAUDE.mdルール1）
//
// `var S: string; S := StringOfChar('x', 300); WriteLn(Length(S))` の結果:
//
//   {$mode objfpc}{$H+}              -> 300
//   {$mode objfpc}{$LONGSTRINGS ON}  -> 300   ($LONGSTRINGS は $H の別名)
//   {$mode objfpc}{$h+ }             -> 300   (閉じ括弧前の空白は許される)
//   {$mode objfpc}(*$H+*)            -> 300   (旧形式も有効)
//   {$mode objfpc}{$H+,I-}           -> 300   (複数スイッチの並記)
//   {$mode objfpc}{$ H+}             -> 255   ($ 直後の空白は指令ではない)
//   {$H+}{$mode objfpc}              -> 255   ★{$mode} が $H を既定値に戻す
//   {$mode objfpc}                   -> 255
//   {$mode fpc} / {$mode tp}         -> 255
//   {$mode delphi}                   -> 300   (delphi だけ $H+ を含意する)
//   {$mode delphi}{$H-}              -> 255
//
// ★の行が重要で、`{$H+}` を `{$mode}` より前に置くと無効になる。したがって
// 指令は**ソース順に状態機械として畳み込む**必要があり、「ファイル内に
// `{$mode objfpc}` と `{$H+}` の両方があるか」という集合判定では誤る。

interface

uses
  SysUtils, Generics.Collections, TSBindings, Diagnostics;

type
  TDirectiveKind = (
    dkOther,        // 関心のない指令
    dkMode,         // {$mode xxx}
    dkLongStrings,  // {$H+} / {$H-} / {$LONGSTRINGS ON|OFF}
    dkInclude,      // {$I file} / {$INCLUDE file}（{$I+} のI/Oチェックは除く）
    dkCondIf,       // {$ifdef} / {$ifndef} / {$if} / {$ifopt}
    dkCondElse,     // {$else} / {$elseif} / {$elsec}
    dkCondEnd       // {$endif} / {$ifend} / {$endc}
  );

  TDirective = record
    Kind: TDirectiveKind;
    // dkMode: 小文字化したモード名（'objfpc' 等）
    // dkLongStrings: '+' または '-'
    // それ以外: 空
    Arg: string;
    StartByte: LongWord;
    // この指令が入れ子の条件ブロック何段目にあるか（0 = 無条件）。
    // 条件付きの指令は「そのビルド構成では有効かどうか分からない」ので、
    // 判定に使うルール側が門番として使う（CLAUDE.mdルール5）。
    CondDepth: Integer;
    Node: TSNode;   // 診断位置の報告用
  end;

  TDirectiveList = specialize TList<TDirective>;

// 部分木から指令を集め、StartByte の昇順（= ソース順）で List に入れる。
// CondDepth も併せて設定する。
procedure CollectDirectives(const Node: TSNode; Ctx: TLintContext;
  List: TDirectiveList);

// そのモードが `$H+`（AnsiString）を含意するか。実測どおり delphi 系のみ True。
// 未知のモード名に対しては False を返す（「$H は既定でオフ」という FPC の
// 本来の既定に倒す）が、呼び出し側は IsKnownModeName で未知を弾く方が安全。
function ModeImpliesLongStrings(const ModeName: string): Boolean;

// data/ のような外部情報に頼らず判定できる、FPC 3.2.2 が受け付けるモード名か。
// 未知の綴りは「rawpaco が知らない方言」なので、判定を諦める材料に使う。
function IsKnownModeName(const ModeName: string): Boolean;

implementation

const
  // fpc 3.2.2 の `{$mode }` が受け付ける値。`fpc -i` 等では列挙できないため、
  // freepascal.org の Programmer's Guide の $MODE の項に挙げられているものを
  // 書き写した（CLAUDE.mdルール1: 実在確認の対象）。delphiunicode は
  // Delphi 互換の Unicode モードで、delphi と同じく $H+ を含意する。
  CKnownModes: array[0..7] of string = (
    'fpc', 'objfpc', 'tp', 'delphi', 'delphiunicode', 'macpas', 'iso', 'extendedpascal'
  );
  CLongStringModes: array[0..1] of string = ('delphi', 'delphiunicode');

function ModeImpliesLongStrings(const ModeName: string): Boolean;
var
  S: string;
begin
  Result := False;
  for S in CLongStringModes do
    if S = LowerCase(ModeName) then
      Exit(True);
end;

function IsKnownModeName(const ModeName: string): Boolean;
var
  S: string;
begin
  Result := False;
  for S in CKnownModes do
    if S = LowerCase(ModeName) then
      Exit(True);
end;

// 指令の中身（`{$` と `}` を除いた部分）を種別と引数に分解する。
//
// 中身は次の2形態のいずれか:
//   (1) 単語形式  … `mode objfpc` / `LONGSTRINGS ON` / `ifdef FOO` / `I file.inc`
//   (2) スイッチ形式 … `H+` / `h+ ` / `H+,I-`（1文字 + `+`/`-` のカンマ区切り）
// `I` は (1) の include と (2) のI/Oチェックで衝突するため、`I` の直後が
// `+`/`-` ならスイッチ、空白なら include と判定する（RuleHalluc001 の
// HasDisablingDirective が採っている区別と同じ）。
procedure ParseDirectiveBody(const Body: string; out Kind: TDirectiveKind;
  out Arg: string);
var
  Trimmed, Word1, Rest, Item: string;
  SpacePos, CommaPos: Integer;
begin
  Kind := dkOther;
  Arg := '';
  Trimmed := Trim(Body);
  if Trimmed = '' then Exit;

  // --- スイッチ形式（1文字 + 符号）を先に判定する ---
  // `H+`、`H+,I-` のような並びは、単語形式のパーサに渡すと `H+,I-` という
  // 1単語に見えてしまうため。
  if (Length(Trimmed) >= 2) and (Trimmed[1] in ['A'..'Z', 'a'..'z']) and
     (Trimmed[2] in ['+', '-']) then
  begin
    // カンマ区切りを手で分解する。`TStringHelper.Split` は objfpc モードでは
    // `{$modeswitch typehelpers}` が必要になるため使わない。
    Rest := Trimmed;
    while Rest <> '' do
    begin
      CommaPos := Pos(',', Rest);
      if CommaPos = 0 then
      begin
        Item := Trim(Rest);
        Rest := '';
      end
      else
      begin
        Item := Trim(Copy(Rest, 1, CommaPos - 1));
        Rest := Copy(Rest, CommaPos + 1, Length(Rest));
      end;
      if (Length(Item) >= 2) and (UpCase(Item[1]) = 'H') and
         (Item[2] in ['+', '-']) then
      begin
        Kind := dkLongStrings;
        Arg := Item[2];
        // 同一指令内に H が複数並ぶことは事実上ないが、最後の指定が勝つので
        // Break せず最後まで見る。
      end;
    end;
    Exit;
  end;

  // --- 単語形式 ---
  SpacePos := Pos(' ', Trimmed);
  if SpacePos = 0 then
  begin
    Word1 := Trimmed;
    Rest := '';
  end
  else
  begin
    Word1 := Copy(Trimmed, 1, SpacePos - 1);
    Rest := Trim(Copy(Trimmed, SpacePos + 1, Length(Trimmed)));
  end;
  Word1 := LowerCase(Word1);

  if Word1 = 'mode' then
  begin
    Kind := dkMode;
    Arg := LowerCase(Rest);
  end
  else if Word1 = 'longstrings' then
  begin
    Kind := dkLongStrings;
    if LowerCase(Rest) = 'on' then Arg := '+' else Arg := '-';
  end
  else if (Word1 = 'i') or (Word1 = 'include') then
    Kind := dkInclude
  else if (Word1 = 'ifdef') or (Word1 = 'ifndef') or (Word1 = 'if') or
          (Word1 = 'ifopt') or (Word1 = 'ifc') then
    Kind := dkCondIf
  else if (Word1 = 'else') or (Word1 = 'elseif') or (Word1 = 'elsec') then
    Kind := dkCondElse
  else if (Word1 = 'endif') or (Word1 = 'ifend') or (Word1 = 'endc') then
    Kind := dkCondEnd;
end;

// ノードのテキストが指令なら、`{$`/`(*$` と閉じ括弧を除いた中身を返す。
// 指令でなければ False。
function TryGetDirectiveBody(const Text: AnsiString; out Body: string): Boolean;
begin
  Result := False;
  Body := '';
  // `{$` の直後に空白がある形（`{$ H+}`）は FPC が指令として扱わない（実測）。
  if (Length(Text) >= 3) and (Text[1] = '{') and (Text[2] = '$') and
     (Text[3] <> ' ') then
  begin
    Body := Copy(Text, 3, Length(Text) - 3); // 末尾の `}` を落とす
    Exit(True);
  end;
  if (Length(Text) >= 5) and (Copy(Text, 1, 3) = '(*$') and (Text[4] <> ' ') then
  begin
    Body := Copy(Text, 4, Length(Text) - 5); // 末尾の `*)` を落とす
    Exit(True);
  end;
end;

// StartByte の昇順を保ったまま挿入する。
//
// 走査順（深さ優先の行きがけ）は葉ノードについてはソース順になるはずだが、
// 指令の順序はこのユニットの判定の根幹（`{$H+}{$mode}` と
// `{$mode}{$H+}` で意味が変わる）なので、走査順に依存せず明示的に並べる。
procedure InsertSorted(List: TDirectiveList; const D: TDirective);
var
  I: Integer;
begin
  I := List.Count;
  while (I > 0) and (List[I - 1].StartByte > D.StartByte) do
    Dec(I);
  List.Insert(I, D);
end;

procedure CollectRaw(const Node: TSNode; Ctx: TLintContext; List: TDirectiveList);
var
  NodeType: PAnsiChar;
  Body: string;
  D: TDirective;
  Count, I: LongWord;
begin
  NodeType := ts_node_type(Node);
  // `pp` は `{$...}` 形式の指令。`comment` は通常のコメントだが、旧形式の
  // `(*$...*)` 指令もここに来る（ユニット冒頭コメント参照）。
  if (NodeType = 'pp') or (NodeType = 'comment') then
  begin
    if TryGetDirectiveBody(Ctx.GetNodeText(Node), Body) then
    begin
      ParseDirectiveBody(Body, D.Kind, D.Arg);
      D.StartByte := ts_node_start_byte(Node);
      D.CondDepth := 0; // 後段で設定する
      D.Node := Node;
      InsertSorted(List, D);
    end;
    Exit;
  end;

  Count := ts_node_named_child_count(Node);
  I := 0;
  while I < Count do
  begin
    CollectRaw(ts_node_named_child(Node, I), Ctx, List);
    Inc(I);
  end;
end;

procedure CollectDirectives(const Node: TSNode; Ctx: TLintContext;
  List: TDirectiveList);
var
  I, Depth: Integer;
  D: TDirective;
begin
  CollectRaw(Node, Ctx, List);

  // ソート済みの並びを前から見て条件ブロックの深さを振る。`{$else}` は
  // 深さを変えない（同じ段の別の枝）。`{$endif}` が余分に現れても深さが
  // 負にならないようにする（構文エラーを含むファイルでも落ちないように）。
  Depth := 0;
  for I := 0 to List.Count - 1 do
  begin
    D := List[I];
    if D.Kind = dkCondEnd then
      if Depth > 0 then Dec(Depth);
    D.CondDepth := Depth;
    List[I] := D;
    if D.Kind = dkCondIf then
      Inc(Depth);
  end;
end;

end.
