unit RuleMem001;

{$mode objfpc}{$H+}

// RAWPACO-MEM-001 / RAWPACO-MEM-002: ローカル変数に生成したオブジェクトの
// 解放漏れ検知。docs/RULE_ENGINE_DESIGN.md 2.8節/P12・P13。
//
// 1ユニット1ルールが原則だが、この2ルールは「どのローカル変数が生成され、
// どこで解放され、それが finally 配下か」という**完全に同一の解析結果**から
// 2つの結論を出すだけの関係にある。別ユニットにすると同じ走査を2回行い、
// 走査ロジックの片方だけを直してしまう危険が生まれるため、例外的に1ユニットに
// 2ルールを置き、`AllRules.pas` からは1回の uses で両方を登録する。
//
//   - MEM-001: ルーチン内に解放が**1つも無い**（全経路でリーク）。Error。
//   - MEM-002: 解放はあるが `finally`（および `except`）配下に無い
//     （例外経路でのみリーク）。Warning。
//
// ■ 検知の骨格
//
// `defProc`（手続き・関数・メソッドの実装本体）1つにつき1回 Check が呼ばれる。
// 1. `[local]` 直下の `declVars` からローカル変数名と宣言型テキストを集める。
// 2. その `defProc` の部分木を1回走査し、各ローカル変数について
//    「生成回数」「解放回数」「finally/except 配下の解放回数」「エスケープしたか」
//    を数える。
// 3. 生成がちょうど1回・エスケープなしの変数だけを判定対象にする。
//
// ■ 誤検知回避の設計（CLAUDE.mdルール5: 疑わしきは見逃す）
//
// このルールの誤検知の主戦場は**所有権の移転**である。生成したオブジェクトを
// 他のオブジェクトに渡した場合、解放責任は渡された側に移るのが普通で、
// このルーチンで解放しないことが正しい。型解決なしに所有権を追うことは
// できないので、「所有権が移った**かもしれない**形が1つでもあれば黙る」
// という強い絞り込みを採る。具体的には、その変数の出現箇所が
// **`L.<メンバ>` という形（`exprDot` の lhs）と生成時の代入先だけ**である
// 場合にのみ判定する。それ以外の出現（引数として渡す `List.Add(L)`、
// 代入の右辺 `Result := L` / `FField := L`、`with L do`、配列添字など）が
// 1つでもあれば、その変数は「エスケープした」とみなして対象から外す。
//   - 例外として `FreeAndNil(L)` だけは引数渡しだが解放として数える
//     （これをエスケープ扱いにすると最も普通の解放形が検知不能になる）。
//
// そのほかの門番:
//   - 生成が2回以上ある変数は対象外（`L := A.Create; L.Free; L := B.Create;`
//     のような再代入の経路解析は構文解析では追えない）。
//   - 宣言型が `I` で始まる変数は対象外。インターフェース型は参照カウントで
//     自動解放され、手で `Free` してはいけない（命名規約 `I` は
//     RAWPACO-STYLE-001 が検証している前提を共有する）。
//   - 宣言型が単純な型参照（`typeref` 直下の `identifier` 1つ）でない場合は
//     対象外。`string`/`array of`/ポインタ型/ジェネリクス等はそもそも
//     `.Create` で生成して `Free` するものではない。
//   - 同一ファイル内で **record として宣言されている型**の生成は対象外。
//     advanced record の `class function Create` は `Free` を必要としない。
//     （ファイル外の record 型は判定できないので残余リスクとして受け入れる。
//       下記「残るリスク」参照。）
//   - ネストした手続き（`[local]` に入る `defProc`）の中での生成は、外側の
//     ルーチンの生成として数えない。一方、**解放とエスケープはネストの中も
//     数える**（内側で解放する／内側で他へ渡すパターンを誤検知しないため）。
//     この非対称性は実測で確認した木の形（ネスト手続きは外側の `[local]`
//     フィールドに `defProc` として入る）に基づく。
//   - 構文エラーを含むファイル（`ts_node_has_error`）は対象外。
//
// ■ 残るリスク（意図的に受け入れたもの。CLAUDE.mdルール8）
//
// - ファイル外で定義された record 型（`TTimeSpan.Create` 等）をローカル変数に
//   生成した場合、クラスと区別できず MEM-001 を誤検知する。型解決なしでは
//   原理的に判定できないため、`data/fpc-rtl-symbols.txt` に型の種別
//   （class/record）を持たせる拡張が入るまではこのリスクが残る。fpc-source
//   全体での実測ではこの形は検知結果に現れなかった。
// - `except` 配下の解放を「保護されている」に数えている。厳密には
//   `try ... except L.Free; raise; end` は成功経路で解放していないが、
//   その場合は try 本体側にも解放があるのが普通であり、except だけを見て
//   未保護と判定すると `後始末して投げ直す` 定型で誤検知が出る
//   （RAWPACO-STYLE-002 が実測で最大の誤検知要因としてぶつかったのと同じ形）。
//
// ■ tree-sitter-pascal(v0.10.2) の実際の文法（プローブで実機確認）
//
// - 手続き・関数の実装は `defProc`。フィールドは `header`(`declProc`)・
//   `local`(multiple: `declVars`/`declConsts`/ネストした `defProc` 等)・
//   `body`(`block`)。宣言だけの `declProc`（interface 部）は `defProc` に
//   ならないので、本体を持つ実装だけが自然に対象になる。
// - `L.Free;`（括弧なし）は `statement` > `exprDot`(lhs=L, rhs=Free)。
//   `L.Free();` は `exprCall`(entity=`exprDot`)。
// - `FreeAndNil(L)` は `exprCall`(entity=identifier"FreeAndNil",
//   args=`exprArgs`(identifier"L"))。
// - `try ... finally ... end` は `try` ノードで、フィールド `try`/`except`/
//   `finally` はいずれも multiple（`kFinally` トークンと中身が同じフィールド名で
//   並ぶ）。
// - `with TStringList.Create do try ... finally Free; end` はローカル変数を
//   使わないため、このルールの対象に自然に入らない（対応不要）。

interface

uses
  SysUtils, Generics.Collections, TSBindings, Diagnostics, RuleRegistry;

type
  TRuleMem001 = class(TInterfacedObject, IRawpacoRule)
  public
    function RuleId: string;
    function Description: string;
    function Severity: TSeverity;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

  TRuleMem002 = class(TInterfacedObject, IRawpacoRule)
  public
    function RuleId: string;
    function Description: string;
    function Severity: TSeverity;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

implementation

uses
  ASTHelpers;

const
  CRuleId001 = 'RAWPACO-MEM-001';
  // 設計書4.1.2節「対応しなかった場合の結果の深刻さ」: ルーチンを通るたびに
  // 確実にメモリが漏れる。発見も困難(症状が出るのは長時間稼働後)。
  // 既定でCIを落とすError階層とする。
  CSeverity001 = svError;

  CRuleId002 = 'RAWPACO-MEM-002';
  // 例外が起きた経路でのみ漏れる。正常系では解放されており、例外を投げない
  // ルーチンなら実害が出ないため、既定ではCIを落とさないWarning階層とする。
  CSeverity002 = svWarning;

type
  TMemCandidate = record
    NameUpper: string;
    TypeText: string;
    CreateNode: TSNode;     // 生成している assignment ノード(報告位置)
    CreateCount: Integer;
    FreeCount: Integer;
    ProtectedFreeCount: Integer; // finally / except 配下の解放
    // ネストした手続きの中で解放している場合。その手続きがどこから呼ばれるか
    // (finally 配下かどうか)は手続き間の解析が必要で構文だけでは分からないため、
    // MEM-002 の判定を諦める材料に使う(CLAUDE.mdルール5)。MEM-001 の方は
    // 「解放が存在する」ことだけが問題なので影響を受けない。
    NestedFreeCount: Integer;
    Escaped: Boolean;
  end;

  TCandidateList = specialize TList<TMemCandidate>;

  TMemScan = class
  private
    FCtx: TLintContext;
    FCandidates: TCandidateList;
    FRecordTypes: TNameSet;   // 同一ファイル内で record として宣言された型名
    FRoot: TSNode;            // 対象の defProc(ネスト判定の基準)
    function IndexOfName(const NameUpper: string): Integer;
    procedure MarkEscaped(const NameUpper: string);
    procedure NoteCreate(const NameUpper: string; const Node: TSNode);
    procedure NoteFree(const NameUpper: string; IsProtected, IsNested: Boolean);
    // 変数名として扱える identifier なら大文字化した名前を返す。
    function TryCandidateName(const Node: TSNode; out NameUpper: string): Boolean;
    function HandleAssignment(const Node: TSNode; InNested: Boolean): Boolean;
    function HandleExprDot(const Node: TSNode; InFinally, InNested: Boolean): Boolean;
    function HandleFreeAndNil(const Node: TSNode; InFinally, InNested: Boolean): Boolean;
  public
    procedure Walk(const Node: TSNode; InNested, InFinally: Boolean);
  end;

// 同一ファイル内で record / object として宣言されている型名を集める。
// クラス・レコード・オブジェクトはいずれも `declClass` ノードで、先頭の子
// トークンが `kClass`/`kRecord`/`kObject` で区別される(RuleDepr002 実装時に
// 確認済みの構造)。record の `class function Create` は Free を必要としないため、
// 解放漏れの判定から外す。
procedure CollectRecordTypes(const Node: TSNode; Ctx: TLintContext; Names: TNameSet);
var
  Count, I: LongWord;
  NameNode, TypeNode, FirstChild: TSNode;
  IsRecord: Boolean;
begin
  if ts_node_type(Node) = 'declType' then
  begin
    if FindFieldChild(Node, 'name', NameNode) and
       FindFieldChild(Node, 'type', TypeNode) and
       (ts_node_type(NameNode) = 'identifier') and
       (ts_node_type(TypeNode) = 'declClass') and
       (ts_node_child_count(TypeNode) > 0) then
    begin
      FirstChild := ts_node_child(TypeNode, 0);
      IsRecord := (ts_node_type(FirstChild) = 'kRecord') or
                  (ts_node_type(FirstChild) = 'kObject');
      if IsRecord then
        Names.AddOrSetValue(UpperCase(Ctx.GetNodeText(NameNode)), True);
    end;
  end;

  Count := ts_node_named_child_count(Node);
  I := 0;
  while I < Count do
  begin
    CollectRecordTypes(ts_node_named_child(Node, I), Ctx, Names);
    Inc(I);
  end;
end;

// コンストラクタ呼び出しが「所有者を渡している可能性のある引数」を持つか。
//
// **これが最大の誤検知対策である**（fpc-source 全体での実測で判明）。Object Pascal
// には `TComponent.Create(AOwner)` という所有権のイディオムがあり、所有者を
// 渡して生成したオブジェクトは所有者が解放するため、ローカルで解放しないことが
// 正しい。`packages/fcl-report` のデモ群がまさにこの形
// （`p := TFPReportPage.Create(rpt);` 等）で、この門番を入れる前は91件の
// 誤検知を出していた。
//
// 引数の意味は型解決なしには判定できないので、
//   - 引数なし（`TStringList.Create` / `TStringList.Create()`）
//   - 引数がちょうど1つで `nil`（`TFoo.Create(nil)` = 所有者なしの明示）
// のみを「所有者を渡していない」とみなし、それ以外の引数が1つでもあれば黙る。
// `TFileStream.Create('f', fmOpenRead)` のような所有者ではない引数も黙る側に
// 倒れるため検知漏れになるが、CLAUDE.mdルール5に従い誤検知を避ける方を採る。
function ConstructorHasOwnerArgument(const RhsNode: TSNode; Ctx: TLintContext): Boolean;
var
  ArgsNode, ArgNode: TSNode;
begin
  Result := False;
  // 括弧なし（`exprDot` 直接）の場合は引数がない。
  if ts_node_type(RhsNode) <> 'exprCall' then Exit;
  if not FindFieldChild(RhsNode, 'args', ArgsNode) then Exit; // `Create()`
  if ts_node_named_child_count(ArgsNode) = 0 then Exit;

  if ts_node_named_child_count(ArgsNode) = 1 then
  begin
    ArgNode := ts_node_named_child(ArgsNode, 0);
    // `nil` は文法上 `nil` ノードになるが、綴りで見れば種別に依存しない。
    if LowerCase(Ctx.GetNodeText(ArgNode)) = 'nil' then Exit;
  end;

  Result := True;
end;

// defProc の `[local]` 直下の declVars からローカル変数を集める。
// ネストした defProc の中の宣言は拾わない(そちらは自分の Check で扱われる)。
procedure CollectLocalVars(const ProcNode: TSNode; Ctx: TLintContext;
  Candidates: TCandidateList; RecordTypes: TNameSet);
var
  LocalNode, VarNode, TypeNode, RefNode, NameNode: TSNode;
  VarCount, I: LongWord;
  C: TMemCandidate;
  TypeText: string;
begin
  for LocalNode in CollectFieldChildren(ProcNode, 'local') do
  begin
    if ts_node_type(LocalNode) <> 'declVars' then Continue;
    VarCount := ts_node_named_child_count(LocalNode);
    I := 0;
    while I < VarCount do
    begin
      VarNode := ts_node_named_child(LocalNode, I);
      Inc(I);
      if ts_node_type(VarNode) <> 'declVar' then Continue;
      // 型が「typeref 直下の identifier 1つ」の単純な形のときだけ対象にする。
      if not FindFieldChild(VarNode, 'type', TypeNode) then Continue;
      if ts_node_named_child_count(TypeNode) <> 1 then Continue;
      RefNode := ts_node_named_child(TypeNode, 0);
      if ts_node_type(RefNode) <> 'typeref' then Continue;
      if ts_node_named_child_count(RefNode) <> 1 then Continue;
      if ts_node_type(ts_node_named_child(RefNode, 0)) <> 'identifier' then Continue;

      TypeText := Ctx.GetNodeText(ts_node_named_child(RefNode, 0));
      // インターフェース型は参照カウントで自動解放されるので対象外。
      if (TypeText <> '') and (UpCase(TypeText[1]) = 'I') then Continue;
      // 同一ファイル内で record/object として宣言された型は Free 不要。
      if RecordTypes.ContainsKey(UpperCase(TypeText)) then Continue;

      // `A, B: TFoo;` のように name は複数ありうる。
      for NameNode in CollectFieldChildren(VarNode, 'name') do
      begin
        if ts_node_type(NameNode) <> 'identifier' then Continue;
        C.NameUpper := UpperCase(Ctx.GetNodeText(NameNode));
        C.TypeText := TypeText;
        C.CreateNode := NameNode; // 生成が見つかった時点で上書きする
        C.CreateCount := 0;
        C.FreeCount := 0;
        C.ProtectedFreeCount := 0;
        C.NestedFreeCount := 0;
        C.Escaped := False;
        Candidates.Add(C);
      end;
    end;
  end;
end;

function TMemScan.IndexOfName(const NameUpper: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to FCandidates.Count - 1 do
    if FCandidates[I].NameUpper = NameUpper then
      Exit(I);
end;

procedure TMemScan.MarkEscaped(const NameUpper: string);
var
  I: Integer;
  C: TMemCandidate;
begin
  I := IndexOfName(NameUpper);
  if I < 0 then Exit;
  C := FCandidates[I];
  C.Escaped := True;
  FCandidates[I] := C;
end;

procedure TMemScan.NoteCreate(const NameUpper: string; const Node: TSNode);
var
  I: Integer;
  C: TMemCandidate;
begin
  I := IndexOfName(NameUpper);
  if I < 0 then Exit;
  C := FCandidates[I];
  Inc(C.CreateCount);
  C.CreateNode := Node;
  FCandidates[I] := C;
end;

procedure TMemScan.NoteFree(const NameUpper: string; IsProtected, IsNested: Boolean);
var
  I: Integer;
  C: TMemCandidate;
begin
  I := IndexOfName(NameUpper);
  if I < 0 then Exit;
  C := FCandidates[I];
  Inc(C.FreeCount);
  if IsProtected then Inc(C.ProtectedFreeCount);
  if IsNested then Inc(C.NestedFreeCount);
  FCandidates[I] := C;
end;

function TMemScan.TryCandidateName(const Node: TSNode; out NameUpper: string): Boolean;
begin
  Result := False;
  NameUpper := '';
  if ts_node_type(Node) <> 'identifier' then Exit;
  NameUpper := UpperCase(FCtx.GetNodeText(Node));
  Result := IndexOfName(NameUpper) >= 0;
end;

// `L := <何か>.Create(...)` を生成として数える。True を返した場合、
// 呼び出し側はこのノードの子を辿らない(生成式の中の識別子を
// エスケープとして数えないため)。
function TMemScan.HandleAssignment(const Node: TSNode; InNested: Boolean): Boolean;
var
  LhsNode, RhsNode: TSNode;
  NameUpper, TypeName: string;
begin
  Result := False;
  if not (FindFieldChild(Node, 'lhs', LhsNode) and
          FindFieldChild(Node, 'rhs', RhsNode)) then Exit;
  if not TryCandidateName(LhsNode, NameUpper) then Exit;

  if TryGetConstructorCallTypeName(RhsNode, FCtx, TypeName) then
  begin
    // 同一ファイル内で record と分かっている型は対象外。
    if FRecordTypes.ContainsKey(UpperCase(TypeName)) then
      MarkEscaped(NameUpper)
    else if ConstructorHasOwnerArgument(RhsNode, FCtx) then
      // 所有者を渡している可能性があるコンストラクタは対象外。
      MarkEscaped(NameUpper)
    else if InNested then
      // ネストした手続きでの生成は外側の生成として数えない。ただし外側から
      // 見ると「どこで生成されたか分からない」状態になるのでエスケープ扱い。
      MarkEscaped(NameUpper)
    else
      NoteCreate(NameUpper, Node);
    Exit(True);
  end;

  // 生成以外の代入(`L := SomethingElse`)は、そのオブジェクトの出自が
  // 追えなくなるのでエスケープ扱いにする。
  MarkEscaped(NameUpper);
  Result := True;
end;

// `L.Free` / `L.Destroy` を解放として数え、`L.<その他>` は中立(メンバ
// アクセス)として扱う。True を返した場合、呼び出し側は lhs を辿らない。
function TMemScan.HandleExprDot(const Node: TSNode; InFinally, InNested: Boolean): Boolean;
var
  LhsNode, RhsNode: TSNode;
  NameUpper, Member: string;
begin
  Result := False;
  if not FindFieldChild(Node, 'lhs', LhsNode) then Exit;
  if not TryCandidateName(LhsNode, NameUpper) then Exit;

  Member := '';
  if FindFieldChild(Node, 'rhs', RhsNode) and
     (ts_node_type(RhsNode) = 'identifier') then
    Member := UpperCase(FCtx.GetNodeText(RhsNode));

  if (Member = 'FREE') or (Member = 'DESTROY') then
    NoteFree(NameUpper, InFinally, InNested);
  // それ以外はメンバアクセス。エスケープでも解放でもない。
  Result := True;
end;

// `FreeAndNil(L)` を解放として数える。True を返した場合、呼び出し側は
// args を辿らない(引数渡しをエスケープとして数えないため)。
function TMemScan.HandleFreeAndNil(const Node: TSNode; InFinally, InNested: Boolean): Boolean;
var
  EntityNode, ArgsNode, ArgNode: TSNode;
  NameUpper: string;
begin
  Result := False;
  if not FindFieldChild(Node, 'entity', EntityNode) then Exit;
  if ts_node_type(EntityNode) <> 'identifier' then Exit;
  if UpperCase(FCtx.GetNodeText(EntityNode)) <> 'FREEANDNIL' then Exit;
  if not FindFieldChild(Node, 'args', ArgsNode) then Exit;
  if ts_node_named_child_count(ArgsNode) <> 1 then Exit;

  ArgNode := ts_node_named_child(ArgsNode, 0);
  if not TryCandidateName(ArgNode, NameUpper) then Exit;

  NoteFree(NameUpper, InFinally, InNested);
  Result := True;
end;

procedure TMemScan.Walk(const Node: TSNode; InNested, InFinally: Boolean);
var
  NodeType: PAnsiChar;
  Count, I: LongWord;
  Child: TSNode;
  ChildField: PAnsiChar;
  NameUpper: string;
  Nested: Boolean;
begin
  NodeType := ts_node_type(Node);

  // ネストした手続き。解放とエスケープは数えるが、生成は外側のものとして
  // 数えない(ユニット冒頭コメントの非対称性)。
  Nested := InNested or ((NodeType = 'defProc') and
                         (ts_node_start_byte(Node) <> ts_node_start_byte(FRoot)));

  if NodeType = 'assignment' then
  begin
    // lhs が候補変数そのものだった場合、その identifier は「使用箇所」ではなく
    // 代入先なのでエスケープに数えない(だから lhs だけ辿らない)。一方
    // **rhs 側は必ず辿る**。ここを辿らないと
    // `aliassym := cabsolutevarsym.create_ref(..., sl);` のように
    // 「別の候補を引数として他へ渡している」形を取りこぼし、所有権が移った
    // オブジェクトを未解放と誤検知する(fpc-source の compiler/symcreat.pas で
    // 実際にこの誤検知が出た)。
    if HandleAssignment(Node, Nested) then
    begin
      Count := ts_node_child_count(Node);
      I := 0;
      while I < Count do
      begin
        ChildField := ts_node_field_name_for_child(Node, I);
        if (ChildField = nil) or (ChildField <> 'lhs') then
          Walk(ts_node_child(Node, I), Nested, InFinally);
        Inc(I);
      end;
      Exit;
    end;
  end;

  if NodeType = 'exprDot' then
    if HandleExprDot(Node, InFinally, Nested) then Exit;

  if NodeType = 'exprCall' then
    if HandleFreeAndNil(Node, InFinally, Nested) then Exit;

  // 宣言ノードの `name` フィールドは「その変数を使っている箇所」ではないので
  // 辿らない。これを素通しにすると、`var L: TStringList;` の `L` 自体が
  // 「メンバアクセスでもない裸の identifier」としてエスケープ扱いになり、
  // ルールが常に黙る（実装時に実際にこれで全サンプル非検知になった）。
  // `defaultValue` 等の他のフィールドは他の変数を参照しうるので辿る。
  if (NodeType = 'declVar') or (NodeType = 'declArg') then
  begin
    Count := ts_node_child_count(Node);
    I := 0;
    while I < Count do
    begin
      ChildField := ts_node_field_name_for_child(Node, I);
      if (ChildField = nil) or (ChildField <> 'name') then
        Walk(ts_node_child(Node, I), Nested, InFinally);
      Inc(I);
    end;
    Exit;
  end;

  // 実装ヘッダ（`procedure TFoo.Bar(A: Integer);`）はルーチン名と引数名の
  // 宣言であって変数の使用箇所ではない。
  if NodeType = 'declProc' then Exit;

  if NodeType = 'try' then
  begin
    // `finally` と `except` の配下を「保護された解放」の位置として扱う。
    // except を含める理由はユニット冒頭コメントの「残るリスク」参照。
    Count := ts_node_child_count(Node);
    I := 0;
    while I < Count do
    begin
      Child := ts_node_child(Node, I);
      ChildField := ts_node_field_name_for_child(Node, I);
      if (ChildField <> nil) and
         ((ChildField = 'finally') or (ChildField = 'except')) then
        Walk(Child, Nested, True)
      else
        Walk(Child, Nested, InFinally);
      Inc(I);
    end;
    Exit;
  end;

  // ここに到達した裸の identifier は、メンバアクセスでも生成でも
  // FreeAndNil でもない出現。所有権が移った可能性があるのでエスケープ。
  if (NodeType = 'identifier') and TryCandidateName(Node, NameUpper) then
    MarkEscaped(NameUpper);

  Count := ts_node_named_child_count(Node);
  I := 0;
  while I < Count do
  begin
    Walk(ts_node_named_child(Node, I), Nested, InFinally);
    Inc(I);
  end;
end;

// 1つの defProc を解析し、候補ごとの生成・解放・エスケープを数える。
// 報告は呼び出し側(各ルールの Check)が行う。
procedure AnalyzeProc(const ProcNode: TSNode; Ctx: TLintContext;
  RecordTypes: TNameSet; Candidates: TCandidateList);
var
  Scan: TMemScan;
begin
  CollectLocalVars(ProcNode, Ctx, Candidates, RecordTypes);
  if Candidates.Count = 0 then Exit;

  Scan := TMemScan.Create;
  try
    Scan.FCtx := Ctx;
    Scan.FCandidates := Candidates;
    Scan.FRecordTypes := RecordTypes;
    Scan.FRoot := ProcNode;
    Scan.Walk(ProcNode, False, False);
  finally
    Scan.Free;
  end;
end;

type
  // ファイル内の各 defProc を解析し、報告するかどうかをルールごとに決める
  // コールバックの型。MEM-001 と MEM-002 は判定条件とメッセージだけが違う。
  TReportProc = procedure(const C: TMemCandidate; Ctx: TLintContext);

// ファイル内の全ての defProc を辿って解析する。
//
// InterestedNodeTypes を `defProc` ではなく `root` にしている理由: record 型の
// 宣言はユニットレベル(その defProc の外)にあるのが普通で、defProc 単位で
// Check が呼ばれると record 門番が実質的に効かなくなる。ファイル単位で1回
// record 型を集めてから各 defProc を見る必要がある。RuleDepr001 と同じく、
// 1ファイル1回の Check の中で自己完結させルールインスタンスに状態を持たせない。
//
// ネストした手続きは、外側の解析で「生成はカウントしない・解放とエスケープは
// カウントする」対象として一度、そして自分自身の defProc として改めて一度
// 解析される。どちらも意図した動作である。
procedure WalkProcs(const Node: TSNode; Ctx: TLintContext; RecordTypes: TNameSet;
  Report: TReportProc);
var
  Count, I: LongWord;
  Candidates: TCandidateList;
  C: TMemCandidate;
begin
  if ts_node_type(Node) = 'defProc' then
  begin
    Candidates := TCandidateList.Create;
    try
      AnalyzeProc(Node, Ctx, RecordTypes, Candidates);
      for C in Candidates do
        Report(C, Ctx);
    finally
      Candidates.Free;
    end;
  end;

  Count := ts_node_named_child_count(Node);
  I := 0;
  while I < Count do
  begin
    WalkProcs(ts_node_named_child(Node, I), Ctx, RecordTypes, Report);
    Inc(I);
  end;
end;

procedure RunAnalysis(const Root: TSNode; Ctx: TLintContext; Report: TReportProc);
var
  RecordTypes: TNameSet;
begin
  RecordTypes := TNameSet.Create;
  try
    CollectRecordTypes(Root, Ctx, RecordTypes);
    WalkProcs(Root, Ctx, RecordTypes, Report);
  finally
    RecordTypes.Free;
  end;
end;

function TRuleMem001.RuleId: string;
begin
  Result := CRuleId001;
end;

function TRuleMem001.Severity: TSeverity;
begin
  Result := CSeverity001;
end;

function TRuleMem001.Description: string;
begin
  Result := 'object created into a local variable is never freed in this routine';
end;

function TRuleMem001.InterestedNodeTypes: TStringArray;
begin
  // root のみ(理由は WalkProcs のコメント参照)。
  Result := TStringArray.Create('root');
end;

procedure ReportMem001(const C: TMemCandidate; Ctx: TLintContext);
begin
  if (C.CreateCount = 1) and (not C.Escaped) and (C.FreeCount = 0) then
    Ctx.Report(CRuleId001, CSeverity001,
      Format('"%s" (%s) is created here but never freed in this routine; ' +
             'wrap the use in try..finally and call %s.Free in the finally block',
             [C.NameUpper, C.TypeText, C.NameUpper]),
      C.CreateNode);
end;

procedure TRuleMem001.Check(const Node: TSNode; Ctx: TLintContext);
begin
  if ts_node_has_error(Node) then Exit;
  RunAnalysis(Node, Ctx, @ReportMem001);
end;

function TRuleMem002.RuleId: string;
begin
  Result := CRuleId002;
end;

function TRuleMem002.Severity: TSeverity;
begin
  Result := CSeverity002;
end;

function TRuleMem002.Description: string;
begin
  Result := 'object created into a local variable is freed, but not from a finally block (leaks if an exception is raised)';
end;

function TRuleMem002.InterestedNodeTypes: TStringArray;
begin
  Result := TStringArray.Create('root');
end;

procedure ReportMem002(const C: TMemCandidate; Ctx: TLintContext);
begin
  if (C.CreateCount = 1) and (not C.Escaped) and
     (C.FreeCount > 0) and (C.ProtectedFreeCount = 0) and
     (C.NestedFreeCount = 0) then
    Ctx.Report(CRuleId002, CSeverity002,
      Format('"%s" (%s) is freed on the normal path only; if anything between ' +
             'the constructor and the Free raises, it leaks. Use ' +
             'try..finally %s.Free; end',
             [C.NameUpper, C.TypeText, C.NameUpper]),
      C.CreateNode);
end;

procedure TRuleMem002.Check(const Node: TSNode; Ctx: TLintContext);
begin
  if ts_node_has_error(Node) then Exit;
  RunAnalysis(Node, Ctx, @ReportMem002);
end;

initialization
  RegisterRule(TRuleMem001.Create);
  RegisterRule(TRuleMem002.Create);

end.
