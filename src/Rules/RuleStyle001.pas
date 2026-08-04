unit RuleStyle001;

{$mode objfpc}{$H+}

// RAWPACO-STYLE-001: 命名規則チェック（設定ファイルベース）。
// docs/RULE_ENGINE_DESIGN.md P5/2.1節に対応。規則は `rawpaco.json` で上書き
// できる（スキーマと既定値は src/RawpacoConfig.pas と docs/CONFIG.md を参照）。
//
// 既定で見るのは、Delphi と Lazarus/FPC の双方で広く合意されている範囲だけ:
//   クラス型名 `T`（例外クラスのため `E` も許可） / object 型名 `T` /
//   record 型名 `T` / インターフェース型名 `I` / 列挙型名 `T` /
//   ポインタ型名 `P` / class の private・protected フィールド `F`
//
// 逆に、意図的に「常に見ない」ものと、その理由（CLAUDE.mdルール5・8）:
//
//   - record / object のフィールド: `F` 接頭辞の慣習はクラスの private
//     フィールド（プロパティのバッキング）に対するものであって、レコードの
//     フィールドには当てはまらない。RTL の TFormatSettings 等がまさにそう。
//   - public / published / 可視性指定なしのクラスフィールド: `F` は非公開
//     フィールドの目印であり、公開フィールドに要求する慣習は無い。
//   - ジェネリック型の型引数（`genericArg` の `T` / `TKey` 等）: 型名では
//     なく型引数であり、命名規則の対象外。
//   - 型別名・手続き型・配列型・集合型・`class of`（`TFoo = Integer` 等）:
//     既定カテゴリに含めない。RTL 自身が `RawByteString` のように接頭辞なしの
//     別名を多用しており、既定で警告するとノイズになる。
//   - 引数の `A` 接頭辞、定数の UPPER_CASE、グローバル変数の `g` 接頭辞、
//     列挙値の接頭辞: コミュニティで揺れているため既定 off。
//
// 接頭辞の照合は大文字小文字を区別する（`T` を要求している以上 `tFoo` は
// 違反とみなすのが自然なため）。一方、接頭辞の直後が大文字であることは
// 要求しない。Lazarus で一般的な `TfrmMain` のような命名を弾かないため。
//
// tree-sitter-pascal(v0.10.2) の実際の文法（プローブプログラムで実機確認済み）:
//   - 型宣言は `declTypes` > `declType`（フィールド `name` / `type`）。
//   - `name` は通常 `identifier` だが、ジェネリック型では `genericTpl`
//     （フィールド `entity` が実際の型名、`args` > `genericArg` > `name` が
//     型引数）になる。
//   - class / object / record はいずれも `type` フィールドが `declClass` に
//     なり、子トークン `kClass` / `kObject` / `kRecord` でしか区別できない。
//     interface は `declIntf`、class helper / record helper は `declHelper`。
//   - 列挙は `type` > `declEnum`、ポインタ型は `type` > `typeref` >
//     `typerefPtr`。
//   - クラス/レコードのフィールドは `declField`（`A, B: Integer;` のように
//     `name` フィールドを複数持ちうる）。可視性は親の `declSection` が持つ
//     `kPrivate` / `kProtected` / `kPublic` / `kPublished`（+ `kStrict`）
//     トークンで判別する。可視性指定が無いフィールドは `declSection` を
//     介さず `declClass` の直下に来る。
//   - クラス内の `class var` は `declField` ではなく `declVars` / `declVar`
//     になるため、このルールの対象に入らない（意図どおり）。

interface

uses
  SysUtils, TSBindings, Diagnostics, RuleRegistry;

type
  TRuleStyle001 = class(TInterfacedObject, IRawpacoRule)
  public
    function RuleId: string;
    function Description: string;
    function Severity: TSeverity;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

implementation

uses
  RawpacoConfig;

const
  CRuleId = 'RAWPACO-STYLE-001';
  // 設計書4.1.2節: プロジェクト固有の好み(かつrawpaco.jsonの`naming.*`で
  // 再設定可能)であり、正しさの問題ではない。既定ではCIを落とさない
  // Warning階層。
  CSeverity = svWarning;

function FindFieldChild(const Node: TSNode; const FieldName: string; out Child: TSNode): Boolean;
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

function HasChildOfType(const Node: TSNode; const TypeName: string): Boolean;
var
  ChildCount, I: LongWord;
begin
  Result := False;
  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    if ts_node_type(ts_node_child(Node, I)) = TypeName then
      Exit(True);
    Inc(I);
  end;
end;

function FirstNamedChild(const Node: TSNode; out Child: TSNode): Boolean;
begin
  Result := ts_node_named_child_count(Node) > 0;
  if Result then
    Child := ts_node_named_child(Node, 0)
  else
    Child := Node;
end;

function MatchesAnyPrefix(const Name: string; const Prefixes: TStringArray): Boolean;
var
  P: string;
begin
  Result := False;
  for P in Prefixes do
    // 大文字小文字を区別する。接頭辞規則の目的そのものなので。
    if Copy(Name, 1, Length(P)) = P then
      Exit(True);
end;

function PrefixListText(const Prefixes: TStringArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Prefixes) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + '"' + Prefixes[I] + '"';
  end;
end;

procedure CheckName(const NameNode: TSNode; Ctx: TLintContext; Category: TNamingCategory);
var
  Prefixes: TStringArray;
  Name: string;
begin
  Prefixes := NamingPrefixes(Category);
  if Length(Prefixes) = 0 then Exit;

  Name := Ctx.GetNodeText(NameNode);
  if Name = '' then Exit;
  if MatchesAnyPrefix(Name, Prefixes) then Exit;

  if Length(Prefixes) = 1 then
    Ctx.Report(CRuleId, CSeverity,
      Format('%s name "%s" does not start with the expected prefix %s',
        [NamingCategoryLabel(Category), Name, PrefixListText(Prefixes)]), NameNode)
  else
    Ctx.Report(CRuleId, CSeverity,
      Format('%s name "%s" does not start with any of the expected prefixes %s',
        [NamingCategoryLabel(Category), Name, PrefixListText(Prefixes)]), NameNode);
end;

// declType の `type` 側から命名カテゴリを決める。既定カテゴリに当てはまらない
// 型（型別名・手続き型・配列型・集合型・class of 等）は False を返す。
function CategoryOfTypeNode(const TypeNode: TSNode; out Category: TNamingCategory): Boolean;
var
  NodeType: PAnsiChar;
  Inner, Inner2: TSNode;
begin
  Result := False;
  Category := ncClass;
  NodeType := ts_node_type(TypeNode);

  if NodeType = 'declClass' then
  begin
    // class / object / record は同じノード種別で、子トークンでしか区別
    // できない。`packed record` のように先頭に別のトークンが来る場合が
    // あるので、位置ではなく存在で判定する。
    if HasChildOfType(TypeNode, 'kClass') then Category := ncClass
    else if HasChildOfType(TypeNode, 'kObject') then Category := ncObject
    else if HasChildOfType(TypeNode, 'kRecord') then Category := ncRecord
    else Exit(False);
    Exit(True);
  end;

  if NodeType = 'declIntf' then
  begin
    Category := ncInterface;
    Exit(True);
  end;

  if NodeType = 'declHelper' then
  begin
    // class helper / record helper。RTL の TStringHelper 等と同じく
    // 型名として `T` 接頭辞の慣習が当てはまるので class と同じ扱いにする。
    Category := ncClass;
    Exit(True);
  end;

  if NodeType = 'type' then
  begin
    if not FirstNamedChild(TypeNode, Inner) then Exit(False);
    if ts_node_type(Inner) = 'declEnum' then
    begin
      Category := ncEnum;
      Exit(True);
    end;
    if ts_node_type(Inner) = 'typeref' then
    begin
      if not FirstNamedChild(Inner, Inner2) then Exit(False);
      if ts_node_type(Inner2) = 'typerefPtr' then
      begin
        Category := ncPointer;
        Exit(True);
      end;
    end;
  end;
end;

procedure CheckTypeDeclaration(const Node: TSNode; Ctx: TLintContext);
var
  NameNode, TypeNode, EntityNode: TSNode;
  Category: TNamingCategory;
begin
  if not FindFieldChild(Node, 'name', NameNode) then Exit;
  if not FindFieldChild(Node, 'type', TypeNode) then Exit;
  if not CategoryOfTypeNode(TypeNode, Category) then Exit;

  if ts_node_type(NameNode) = 'genericTpl' then
  begin
    // `generic TFoo<T> = class` の型名は genericTpl の entity 側。
    // args 側（型引数）は命名規則の対象外なので触らない。
    if not FindFieldChild(NameNode, 'entity', EntityNode) then Exit;
    NameNode := EntityNode;
  end;

  if ts_node_type(NameNode) <> 'identifier' then Exit;
  CheckName(NameNode, Ctx, Category);
end;

procedure CheckPrivateFields(const Node: TSNode; Ctx: TLintContext);
var
  ChildCount, I, SecCount, J, FieldCount, K: LongWord;
  Section, Field, NameChild: TSNode;
  FieldName: PAnsiChar;
begin
  // class 以外（object / record）のフィールドは対象外。
  if not HasChildOfType(Node, 'kClass') then Exit;

  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    Section := ts_node_child(Node, I);
    if (ts_node_type(Section) = 'declSection') and
       (HasChildOfType(Section, 'kPrivate') or HasChildOfType(Section, 'kProtected')) then
    begin
      SecCount := ts_node_child_count(Section);
      J := 0;
      while J < SecCount do
      begin
        Field := ts_node_child(Section, J);
        if ts_node_type(Field) = 'declField' then
        begin
          // `A, B: Integer;` のように name が複数ありうる。
          FieldCount := ts_node_child_count(Field);
          K := 0;
          while K < FieldCount do
          begin
            FieldName := ts_node_field_name_for_child(Field, K);
            if (FieldName <> nil) and (FieldName = 'name') then
            begin
              NameChild := ts_node_child(Field, K);
              if ts_node_type(NameChild) = 'identifier' then
                CheckName(NameChild, Ctx, ncPrivateField);
            end;
            Inc(K);
          end;
        end;
        Inc(J);
      end;
    end;
    Inc(I);
  end;
end;

function TRuleStyle001.RuleId: string;
begin
  Result := CRuleId;
end;

function TRuleStyle001.Severity: TSeverity;
begin
  Result := CSeverity;
end;

function TRuleStyle001.Description: string;
begin
  Result := 'identifier does not follow the configured naming convention';
end;

function TRuleStyle001.InterestedNodeTypes: TStringArray;
begin
  // このルールはノード単位で完結する（他のルールと違いファイル全体を見る
  // 必要がない）ので、root ではなく実際に見たいノード種別を宣言する。
  // 入れ子のクラス・レコードも ASTWalker が個別に訪れるため取りこぼさない。
  Result := TStringArray.Create('declType', 'declClass');
end;

procedure TRuleStyle001.Check(const Node: TSNode; Ctx: TLintContext);
begin
  if not NamingCheckEnabled then Exit;

  if ts_node_type(Node) = 'declType' then
    CheckTypeDeclaration(Node, Ctx)
  else if ts_node_type(Node) = 'declClass' then
    CheckPrivateFields(Node, Ctx);
end;

initialization
  RegisterRule(TRuleStyle001.Create);

end.
