unit ASTHelpers;

{$mode objfpc}{$H+}

// 複数のルールユニットが同じ形で必要とする、tree-sitter ノード走査の小さな
// 補助関数を集めたユニット。
//
// なぜ共有ユニットにしたのか（CLAUDE.mdルール8）:
// ルールを1つずつ実装していく過程で、`FindFieldChild`（ノードの特定フィールドの
// 子を取る）が RuleHalluc001 / RuleStyle001 に一字一句同じ形で2つ存在し、さらに
// 同じ while ループが他7ユニットにインラインで散っていた。`CollectUsedUnits`
// （uses 節のユニット名収集）と `CollectDeclaredNames`（ファイル内の宣言名収集）も
// RuleDepr002 / RuleHalluc001 で完全に同じ実装が2つあった。いずれも
// tree-sitter-pascal の文法構造そのものに対応する操作であり、特定ルールの
// 判定方針とは独立しているため、ここに集約して1箇所で保守する。
//
// 逆に、ここに置かないと決めたもの（境界の判断。将来の追加時の指針）:
//   - 判定の意味づけ（何を問題とみなすか）を含むものは各ルールに残す。当初は
//     「`.Create` をコンストラクタとみなす」ヒューリスティックを含む
//     `IsCreateCall`（RuleDefense002）も理由の1つとして挙げていたが、
//     RAWPACO-MEM-001/002 が2人目の利用者として現れ、同じ木の形
//     （`exprDot` / `exprCall`+entity の2パターン）を二重に読む状態になったため、
//     **形の判定だけを `TryGetConstructorCallTypeName` として下に切り出した**
//     （近似を受け入れるかどうかの判断は各ルールに残してある）。
//   - 1ユニットしか使っていない補助関数（`HasChildOfType` 等）は、重複が
//     存在しない段階で移すと利用箇所から遠いだけで利点がないため残す。
//     2つ目の利用者が現れた時点でここへ移す。
//   - 「全子ノードをフィールド名付きで順に辿る」形（RuleDepr002 / RuleHalluc001
//     の `Walk`、RuleStyle002 の `Scan`）は、特定フィールドの検索ではなく
//     走査そのもの（各ルール固有の枝刈り・状態伝播と一体）なので畳まない。

interface

uses
  SysUtils, Generics.Collections, TSBindings, Diagnostics;

type
  TSNodeArray = array of TSNode;

  // 大文字化した名前の集合（値は常に True。存在判定にのみ使う）。
  TNameSet = specialize TDictionary<string, Boolean>;
  // uses 節に現れたユニット名（元の綴りのまま保持する。比較は CompareText で
  // 大文字小文字を無視して行う）。
  TUnitList = specialize TList<string>;

// Node の「フィールド名が FieldName である子」のうち**最初の1件**を返す。
// 見つからなければ False。
//
// NAMED 子ではなく全ての子を走査する必要がある点に注意。
// ts_node_field_name_for_child のインデックスは匿名トークン（`:=` や `.` 等）も
// 含む全子のインデックスなので、ts_node_named_child_count で回すと対応が崩れる。
//
// 「最初の1件」であることの含意（Fable5.1のレビューで判明、実機確認済み）:
// `exprDot`/`exprBinary`/`assignment` の `lhs`/`rhs`、`exprCall` の `entity`、
// `if` の `condition`、`with` の `entity` は node-types.json 上 multiple=true に
// なっている。その唯一の原因は grammar.js の `_ref` が
// `seq($.kSpecialize, $.identifier)` という選択肢を持つことで（文法側に
// 「本来は exprTpl に入れたいが規則衝突するのでここに置いている」というTODO
// コメントがある）、`specialize SysUtils.Foo` と書くと当該フィールドに
// `kSpecialize` と `identifier` の2件が並び、本関数は `kSpecialize` を返す。
// 呼び出し側はいずれも直後に `ts_node_type(...) = 'identifier'` 等の型チェックを
// 行っているため、この形は自然に対象外になる（報告しない側＝安全側に倒れる。
// CLAUDE.mdルール5）。なおテンプレート引数を伴わない `specialize X.Y` は
// FPCとして無効な構文であり、fpc-source 全4894ファイルにも該当形は存在しない
// （`grep -rE '\bspecialize\s+\w+\s*\.'` で0件）。正当な
// `specialize TFPGList<Integer>.Create` では2件並びが `exprTpl` の内側に閉じる
// ため、exprDot の lhs は1件のままになる。
function FindFieldChild(const Node: TSNode; const FieldName: string;
  out Child: TSNode): Boolean;

// Node の「フィールド名が FieldName である子」を出現順に全て返す。
//
// FindFieldChild と分かれている理由: tree-sitter-pascal には同じフィールド名が
// 複数回現れるフィールド（node-types.json でいう multiple=true）があり、最初の
// 1つだけを見ると取りこぼす。実際に複数並ぶのは以下:
//   - `try` の `except` / `finally`（kExceptトークン + 中身）
//   - `declProc` の `attribute`（`cdecl; deprecated;` のように複数の指令が並ぶ）
//   - `declVar` / `declField` / `declArg` の `name`（`A, B: Integer` の区切りの
//     `,` トークンも同じフィールド名で並ぶので、identifier型のフィルタが必要）
//   - `with` の `entity`（`with A, B do`）
//   - `exprDot`/`exprBinary`/`assignment` の `lhs`/`rhs`、`exprCall` の `entity`、
//     `if` の `condition` — ただしこれらが multiple なのは `specialize X` 由来で、
//     詳細と「FindFieldChild で足りる理由」は上記 FindFieldChild のコメント参照。
function CollectFieldChildren(const Node: TSNode; const FieldName: string): TSNodeArray;

// 部分木から uses 節のユニット名を集める。`unit Foo;` のユニット名自体も
// moduleName ノードになるため、declUses の直下に限定して拾う。
procedure CollectUsedUnits(const Node: TSNode; Ctx: TLintContext; Units: TUnitList);

// 部分木の全ての宣言名（親ノードのフィールド名が `name` の identifier）を
// 大文字化して集める。
//
// ジェネリック型 `generic TFoo<T> = class` の名前は `genericTpl` ノードになり
// identifier ではないため、`genericTpl` / `genericArg` 配下の identifier
// （型名と型引数の両方）はフィールド名を問わずまとめて拾う。
//
// この集合の用途は両方の呼び出し元（RAWPACO-DEPR-002 のシャドウイング対策、
// RAWPACO-HALLUC-001 の「ファイル内で宣言されている名前は未知扱いしない」）とも
// 「警告を抑制する側」なので、多めに拾う方向の緩さは安全側に倒れる。
procedure CollectDeclaredNames(const Node: TSNode; Ctx: TLintContext; Names: TNameSet);

// Units の中から Name と（大文字小文字を無視して）一致するものを、元の綴りの
// まま返す。見つからなければ空文字列。
//
// 比較時は両側から空白・改行を落とす。`uses Generics.Collections;` を改行を
// 挟んで書いた場合や、`Generics . Collections` のような修飾子から取り出した
// テキストと突き合わせられるようにするため（通常のユニット名に空白は無いので
// 既存の挙動は変わらない）。
function FindUnitByName(Units: TUnitList; const Name: string): string;

// `exprDot` の lhs を「ユニット修飾子」として読み出す。
//
// `SysUtils.Foo` のように lhs が単純な `identifier` の場合と、
// `Generics.Collections.TList` や `mormot.core.text.FormatUTF8` のように
// **lhs 自体がドットで繋がった `exprDot`** になる場合の両方に対応する。
// `exprDot` は左結合なので、外側のノードの lhs には常に「最後の識別子より前の
// 全体」が入る（実機確認済み）。したがって lhs のテキストをそのまま修飾子として
// 読めばよく、再帰は不要。
//
// `Horse.Core.GetHorse.Listen(...)` のように「ユニット名の後にさらにメンバが
// 続く」形では、外側の exprDot の lhs は `Horse.Core.GetHorse` でユニット名に
// 一致しないが、その内側の exprDot の lhs は `Horse.Core` で一致する。
// 呼び出し側の走査が入れ子の exprDot も訪れる限り、適切な段で自然に一致する。
//
// FirstSegment には先頭のセグメント（`Generics.Collections` なら `Generics`）を
// 返す。呼び出し側が「同名のローカル変数・型がファイル内で宣言されていないか」を
// 確認するために使う。
function TryGetDotQualifier(const DotNode: TSNode; Ctx: TLintContext;
  out Qualifier, FirstSegment: string): Boolean;

// 式ノードが `<何か>.Create` または `<何か>.Create(...)` の形（括弧の有無を
// 問わない）なら True を返し、`.Create` の左側のテキスト（型名として書かれて
// いる部分）を TypeName に入れる。
//
// **ここに含まれるヒューリスティック**: 「`.Create` という名前のメソッド呼び出しは
// コンストラクタである」という近似が入っている。rawpaco は型解決をしないため、
// 同名のファクトリメソッドやレコードの `class function Create` と区別できない。
// Object Pascal では `.Create` = コンストラクタという命名慣習が非常に強いため
// 実用上はこの近似で足りるが、**この近似を受け入れるかどうかの判断は各ルールの
// 責任**である（このユニットは形の判定だけを提供する）。RAWPACO-DEFENSE-002 と
// RAWPACO-MEM-001/002 がいずれもこの近似を前提にしており、2ルールで同じ木の形を
// 二重に読んでいたため、形の判定部分だけをここへ集約した。
//
// tree-sitter-pascal(v0.10.2) の形（実機確認済み）:
//   `Obj := TFoo.Create;`   -> rhs が `exprDot`(lhs=TFoo, rhs=Create)
//   `Obj := TFoo.Create();` -> rhs が `exprCall`(entity=`exprDot`)
function TryGetConstructorCallTypeName(const Node: TSNode; Ctx: TLintContext;
  out TypeName: string): Boolean;

// root 直下に `unit` / `program` / `library` があるか。
//
// これが False のファイルは「`{$i}` で他ファイルに取り込まれる前提の断片」
// （`declTypes`/`declVars` 等が root 直下に直接並ぶ形）であり、ファイル単位で
// 完結する前提の判定（宣言がこのファイル内にあるか、コンパイラ指令がこの
// ファイル内で揃っているか等）は成立しない。そういう判定を行うルールは
// これを門番に使う（CLAUDE.mdルール5）。
function IsCompilationUnit(const Root: TSNode): Boolean;

implementation

function FindFieldChild(const Node: TSNode; const FieldName: string;
  out Child: TSNode): Boolean;
var
  ChildCount, I: LongWord;
  F: PAnsiChar;
begin
  Result := False;
  Child := Node;
  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    F := ts_node_field_name_for_child(Node, I);
    if (F <> nil) and (F = FieldName) then
    begin
      Child := ts_node_child(Node, I);
      Exit(True);
    end;
    Inc(I);
  end;
end;

function CollectFieldChildren(const Node: TSNode; const FieldName: string): TSNodeArray;
var
  ChildCount, I: LongWord;
  F: PAnsiChar;
  Found: TSNodeArray;
begin
  // Result に直接 SetLength していくと、FPC が「管理型の関数結果変数が
  // 初期化されていないように見える」と警告する。RuleRegistry.AllRuleIds と
  // 同じく、ローカル変数に組み立ててから代入する。
  SetLength(Found, 0);
  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    F := ts_node_field_name_for_child(Node, I);
    if (F <> nil) and (F = FieldName) then
    begin
      SetLength(Found, Length(Found) + 1);
      Found[High(Found)] := ts_node_child(Node, I);
    end;
    Inc(I);
  end;
  Result := Found;
end;

procedure CollectUsedUnits(const Node: TSNode; Ctx: TLintContext; Units: TUnitList);
var
  NamedCount, J: LongWord;
  Child: TSNode;
begin
  if ts_node_type(Node) = 'declUses' then
  begin
    NamedCount := ts_node_named_child_count(Node);
    J := 0;
    while J < NamedCount do
    begin
      Child := ts_node_named_child(Node, J);
      if ts_node_type(Child) = 'moduleName' then
        Units.Add(Ctx.GetNodeText(Child));
      Inc(J);
    end;
    Exit;
  end;

  NamedCount := ts_node_named_child_count(Node);
  J := 0;
  while J < NamedCount do
  begin
    CollectUsedUnits(ts_node_named_child(Node, J), Ctx, Units);
    Inc(J);
  end;
end;

procedure CollectDeclaredNames(const Node: TSNode; Ctx: TLintContext; Names: TNameSet);
var
  ChildCount, I, NamedCount, J: LongWord;
  Child: TSNode;
  FieldName: PAnsiChar;
  InGenericTpl: Boolean;
begin
  InGenericTpl := (ts_node_type(Node) = 'genericTpl') or (ts_node_type(Node) = 'genericArg');
  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    FieldName := ts_node_field_name_for_child(Node, I);
    if InGenericTpl or ((FieldName <> nil) and (FieldName = 'name')) then
    begin
      Child := ts_node_child(Node, I);
      if ts_node_type(Child) = 'identifier' then
        Names.AddOrSetValue(UpperCase(Ctx.GetNodeText(Child)), True);
    end;
    Inc(I);
  end;

  NamedCount := ts_node_named_child_count(Node);
  J := 0;
  while J < NamedCount do
  begin
    CollectDeclaredNames(ts_node_named_child(Node, J), Ctx, Names);
    Inc(J);
  end;
end;

function StripWhitespace(const S: string): string;
var
  I: Integer;
  Buf: string;
begin
  Buf := '';
  for I := 1 to Length(S) do
    if not (S[I] in [' ', #9, #10, #13]) then
      Buf := Buf + S[I];
  Result := Buf;
end;

function FindUnitByName(Units: TUnitList; const Name: string): string;
var
  U, Target: string;
begin
  Result := '';
  Target := StripWhitespace(Name);
  for U in Units do
    if CompareText(StripWhitespace(U), Target) = 0 then
      Exit(U);
end;

function TryGetDotQualifier(const DotNode: TSNode; Ctx: TLintContext;
  out Qualifier, FirstSegment: string): Boolean;
var
  LhsNode: TSNode;
  LhsType: PAnsiChar;
  DotPos: Integer;
begin
  Result := False;
  Qualifier := '';
  FirstSegment := '';
  if not FindFieldChild(DotNode, 'lhs', LhsNode) then Exit;

  LhsType := ts_node_type(LhsNode);
  if (LhsType <> 'identifier') and (LhsType <> 'exprDot') then Exit;

  Qualifier := StripWhitespace(Ctx.GetNodeText(LhsNode));
  if Qualifier = '' then Exit;

  DotPos := Pos('.', Qualifier);
  if DotPos > 0 then
    FirstSegment := Copy(Qualifier, 1, DotPos - 1)
  else
    FirstSegment := Qualifier;

  Result := True;
end;

function TryGetConstructorCallTypeName(const Node: TSNode; Ctx: TLintContext;
  out TypeName: string): Boolean;
var
  EntityNode, DotNode, DotLhsNode, DotRhsNode: TSNode;
  NodeType: PAnsiChar;
begin
  Result := False;
  TypeName := '';
  NodeType := ts_node_type(Node);

  if NodeType = 'exprDot' then
    DotNode := Node
  else if NodeType = 'exprCall' then
  begin
    if not (FindFieldChild(Node, 'entity', EntityNode) and
            (ts_node_type(EntityNode) = 'exprDot')) then
      Exit; // Foo()のような単純呼び出しはexprDotを経由しないため対象外
    DotNode := EntityNode;
  end
  else
    Exit; // 単純呼び出しでも.呼び出しでもない(定数・別の式等)は対象外

  if not FindFieldChild(DotNode, 'rhs', DotRhsNode) then Exit;
  if ts_node_type(DotRhsNode) <> 'identifier' then Exit;
  if UpperCase(Ctx.GetNodeText(DotRhsNode)) <> 'CREATE' then Exit;

  if FindFieldChild(DotNode, 'lhs', DotLhsNode) then
    TypeName := Ctx.GetNodeText(DotLhsNode);
  Result := True;
end;

function IsCompilationUnit(const Root: TSNode): Boolean;
var
  Count, I: LongWord;
  T: PAnsiChar;
begin
  Result := False;
  Count := ts_node_named_child_count(Root);
  I := 0;
  while I < Count do
  begin
    T := ts_node_type(ts_node_named_child(Root, I));
    if (T = 'unit') or (T = 'program') or (T = 'library') then
      Exit(True);
    Inc(I);
  end;
end;

end.
