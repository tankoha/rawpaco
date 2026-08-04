unit RuleStyle002;

{$mode objfpc}{$H+}

// RAWPACO-STYLE-002: 同一ファイル内でのエラーハンドリングの不統一(近似検知)。
// docs/RULE_ENGINE_DESIGN.md P9/2.1節に対応。
//
// ■ このルールが「近似」である理由(CLAUDE.mdルール8: false positive回避の
//   ための緩め実装には理由コメント必須)
//
// 本来検知したい問題は「同じ意味的な操作を、ある箇所ではtry-exceptで保護し、
// 別の箇所では素通しにしている」という一貫性のムラである。しかし
// 「この2つの呼び出しは意味的に同種の操作である」という判断には型解決・
// スコープ解決が必要で、tree-sitter-pascalの構文解析だけでは原理的に
// できない(設計書0節)。そこで本ルールは、意味の同一性を判定せず
// **表面上のAPI呼び出し名の完全一致**だけで「同種の操作」を近似する。
//
// この近似が過剰に発火しないよう、以下の絞り込みを重ねている。いずれも
// 「検知漏れを許容してでも誤検知を避ける」というCLAUDE.mdルール5に沿った
// 意図的なスコープ限定である。
//
// (a) 対象とする呼び出し名を、固定の短いリスト(下記CSystemFileApis /
//     CSysUtilsApis)に限定する。「同一ファイル内でtry内/try外に同じ名前が
//     混在する呼び出し」を無条件に拾うと、`Format`や`WriteLn`のような
//     ごく普通のユーティリティ呼び出しまで全て候補になり実用に耐えない。
//     採用したのは「失敗しうる外部リソース操作／例外を送出する変換」であり、
//     かつ「その名前で修飾なし呼び出しされていればRTLのそれとみなして
//     まず間違いない」ものだけである。
//     - 意図的に外した名前の例と理由:
//       * `Assign`: 設計書は例として挙げているが、`TPersistent.Assign` /
//         `TStrings.Assign`という極めて一般的なメソッド名と衝突する。
//         クラスのメソッド内から`Assign(Src)`と修飾なしで自メソッドを
//         呼ぶ書き方は普通にあり、誤検知の温床になるため除外した
//         (ファイル版は`AssignFile`で書かれる方が現代のFPCでは一般的)。
//       * `Append` / `Erase` / `Flush` / `Seek` / `Truncate` / `Close`:
//         いずれもユーザー定義メソッド名として頻出する一方、ファイルI/Oと
//         しての使用頻度は`Reset`/`Rewrite`に比べ大幅に低く、
//         費用対効果が合わないため除外した。
//     - `Reset`だけは曖昧さがある(状態リセット用のメソッド名として使われる)
//       が、classic Pascalのファイル入力オープンの中心的な手続きであり
//       これを外すとファイルI/O系の検知がほぼ機能しなくなるため残した。
//       代わりに後述(c)の「引数が1つ以上あること」で、引数なしの
//       `Reset;`(ユーザー定義メソッドの典型形)を除外している。
//
// (b) `SysUtils`由来の名前(CSysUtilsApis)は、そのファイルの`declUses`の
//     どこかに`SysUtils`が現れる場合のみ対象とする。設計書が「難しい点」
//     として挙げていた「declUsesで絞るか」への回答がこれ。一方
//     CSystemFileApisの側は絞らない。`AssignFile`/`CloseFile`は`objpas`、
//     `Reset`/`Rewrite`/`BlockRead`/`BlockWrite`は`system`ユニットにあり、
//     どちらもobjfpc/delphiモードで暗黙にusesされるため`uses`節には現れず、
//     ここで絞ると常に検知ゼロになってしまう(P7で`AssignFile`/`CloseFile`が
//     `system`ではなく`objpas`にあると判明した経緯も参照)。
//
// (c) 修飾なし(`entity`が単純な`identifier`)かつ引数が1つ以上ある
//     `exprCall`のみを呼び出しとみなす。
//     - `Obj.Reset(X)`のような修飾付き呼び出し(entityが`exprDot`)は対象外。
//       ユーザー定義オブジェクトのメソッドである可能性が高い。
//     - 括弧なし呼び出し(`Foo;`。P4/RuleDepr001.pasで確立した`statement`が
//       唯一の子としてidentifierを持つ形)も**意図的に対象外**とする。
//       対象リストのRTL手続きは全て引数を1つ以上取るため、引数なしの裸の
//       呼び出しは定義上それらではありえず、拾っても誤検知が増えるだけ。
//
// (d) 引数が全て定数リテラル(`StrToInt('42')`等)の呼び出しは、保護の有無を
//     数える対象から外す。入力が開発者の書いた固定値である以上、そこに
//     try-exceptが無いことは「不統一」の証拠にならない(むしろ保護不要)。
//
// (e) except節の中で例外を送出しているtry(`try ... except FreeAndNil(X);
//     Raise; end;`という後始末＋投げ直しの定型)は「保護」に数えない。
//     詳細と実測の根拠は下の TryHasHandlingExcept のコメント参照。
//
// なお、RAWPACO-HALLUC-001が行っている「`ts_node_has_error`が真のファイルは
// 丸ごとスキップする」門番は、このルールでは**採用しなかった**。理由は
// tree-sitter-pascal v0.10.2が引数なしの再送出`raise;`を構文として
// 受け付けず`ERROR`ノードにしてしまうため(下記参照)。`raise;`はPascalで
// ごく普通の書き方であり、fpc-sourceで本ルールの対象APIとexceptの両方を
// 含む182ファイルのうち111ファイル(61%)が`ts_node_has_error`で真になる。
// 門番を入れるとルールが実質的に無効化される。一方この`ERROR`ノードは
// 文の位置に局所的に現れるだけでtryの境界(try/except/finallyフィールドの
// 構造)は保たれることをプローブで確認しており、保護状態の判定は狂わない。
// 実測でもfpc-source全4894ファイルに対し、門番の有無にかかわらず検知は
// 0件だった。
//
// ■ 「保護されている」の定義(設計上の判断。P1で検証済みのtry構造に基づく)
//
// try/except/finally全体は単一ノード種別`try`で、フィールドは
// `try`(本体、`statements`型)・`except`(multiple)・`finally`(multiple)。
// 走査時に3状態を伝播させる:
//
//   - psProtected  : `except`節を持つ`try`ノードの`try`フィールド配下。
//     `finally`しか持たない`try`の本体は**保護とみなさない**。finallyは
//     後始末を保証するだけで例外を捕捉しないため、「エラーハンドリングを
//     している」とは言えない。ここを保護扱いにすると、
//     `AssignFile(F,..); try Reset(F); ... finally CloseFile(F); end;`
//     というPascalの最も正しい定型パターンが「Resetは保護、AssignFileは
//     未保護」と読まれて誤検知になる。
//   - psIgnored    : `except`節・`finally`節の**中身**。ここで例外が起きても
//     捕捉されないので厳密には未保護だが、未保護として数えると上記の定型
//     パターンの`finally CloseFile(F)`が毎回未保護側に計上され、他所の
//     保護された`CloseFile`と混在扱いになって誤検知が出る。後始末や
//     エラー処理そのものを書く場所なので、保護／未保護のどちらにも
//     数えず単に無視する。
//     ただし外側にさらに`except`付きの`try`がある場合(psProtectedから
//     入った場合)は実際に保護されているのでpsProtectedを維持する。
//   - psUnprotected: 上記以外。
//
// ■ 残る誤検知の余地(意図的に受け入れているもの)
//
// 手続きAが生の入出力を行い、呼び出し元Bがそれをtry-exceptで包む、という
// 責務分離をしている場合、Aの中の呼び出しは「未保護」に数えられる。
// 呼び出しグラフを追わないため区別できない。同一ファイル内で同名APIの
// 保護／未保護が混在する場合のみ報告する、という条件自体がこの種の誤検知を
// 大きく減らすが、ゼロにはできない。ルールの位置づけが「STYLE(一貫性の
// 指摘)」であり、断定的な欠陥指摘ではないことでバランスを取っている。

interface

uses
  SysUtils, TSBindings, Diagnostics, RuleRegistry;

type
  TRuleStyle002 = class(TInterfacedObject, IRawpacoRule)
  public
    function RuleId: string;
    function Description: string;
    function Severity: TSeverity;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

implementation

const
  CRuleId = 'RAWPACO-STYLE-002';
  // 設計書4.1.2節: 設計書2.1節・P9エントリで明記済みの通り、同一ファイル内
  // 近似による緩いヒューリスティックであり、構文だけでは完全に判定できない
  // 問題への近似(誤検知率とは独立に、性質として助言的)。既定ではCIを
  // 落とさないWarning階層。
  CSeverity = svWarning;

  // system / objpas ユニットの古典的ファイルI/O手続き。objfpc/delphiモードで
  // 暗黙にusesされるため`uses`節での絞り込みはできない(冒頭コメント(b))。
  CSystemFileApis: array[0..5] of string = (
    'ASSIGNFILE', 'CLOSEFILE', 'RESET', 'REWRITE', 'BLOCKREAD', 'BLOCKWRITE');

  // SysUtilsの変換関数。失敗時にEConvertErrorを送出するため、try-exceptで
  // 包むか包まないかの流儀のブレが出やすい。名前が十分に特徴的で
  // ユーザー定義関数と衝突しにくい。
  CSysUtilsApis: array[0..7] of string = (
    'STRTOINT', 'STRTOINT64', 'STRTOFLOAT', 'STRTOCURR',
    'STRTODATE', 'STRTOTIME', 'STRTODATETIME', 'STRTOBOOL');

type
  // 走査中に伝播させる保護状態(冒頭コメント「『保護されている』の定義」参照)。
  TProtectionState = (psUnprotected, psProtected, psIgnored);

  TCallSite = record
    NameUpper: string;
    Node: TSNode;      // 報告位置に使う entity の identifier ノード
    NameText: string;  // 報告メッセージ用の元の綴り
  end;

  TScanResult = record
    ProtectedNames: array of string; // try-except配下で見つかった名前(大文字化)
    UnprotectedSites: array of TCallSite;
    SysUtilsUsed: Boolean;
  end;

function ContainsName(const List: array of string; const NameUpper: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(List) to High(List) do
    if List[I] = NameUpper then
      Exit(True);
end;

// この名前を監視対象とみなすか。SysUtils由来の名前だけはusesでの絞り込みを
// 行う(冒頭コメント(b))。
function IsWatchedApi(const NameUpper: string; SysUtilsUsed: Boolean): Boolean;
begin
  Result := ContainsName(CSystemFileApis, NameUpper) or
    (SysUtilsUsed and ContainsName(CSysUtilsApis, NameUpper));
end;

// ファイル内のいずれかの`declUses`に`SysUtils`があるか。interface部と
// implementation部の双方にuses節がありうるため、木全体を対象にする。
function FindSysUtilsInUses(const Node: TSNode; Ctx: TLintContext): Boolean;
var
  NamedCount, I: LongWord;
  Child: TSNode;
begin
  Result := False;
  NamedCount := ts_node_named_child_count(Node);

  // `unit Foo;`のユニット名自体も`moduleName`ノードになるため、`declUses`の
  // 直下に限定して比較する(木全体からmoduleNameを拾うとユニット名を
  // uses節と取り違える)。
  if ts_node_type(Node) = 'declUses' then
  begin
    I := 0;
    while I < NamedCount do
    begin
      Child := ts_node_named_child(Node, I);
      if (ts_node_type(Child) = 'moduleName') and
         (UpperCase(Ctx.GetNodeText(Child)) = 'SYSUTILS') then
        Exit(True);
      Inc(I);
    end;
    Exit;
  end;

  I := 0;
  while I < NamedCount do // LongWordは符号なしのため to Count-1 は使えない
                          // (子0個でアンダーフローする。ASTWalker.pas参照)
  begin
    if FindSysUtilsInUses(ts_node_named_child(Node, I), Ctx) then
      Exit(True);
    Inc(I);
  end;
end;

// 部分木のどこかに`kRaise`トークンがあるか。
//
// tree-sitter-pascal(v0.10.2)の実測: 引数付きの`raise E.Create(..);`は
// `raise`ノード(フィールド`exception`)になるが、**引数なしの再送出
// `raise;`は文法が受け付けず`ERROR`ノード(子に`kRaise`)になる**。
// よって「`raise`ノードを探す」だけでは再送出を取りこぼすため、
// 両方に共通して現れる`kRaise`トークン自体を探す。
// 無名の子にも降りる必要はないが、`ERROR`配下の並びを取りこぼさないよう
// NAMEDではなく全子ノードを辿る。
function SubtreeHasRaise(const Node: TSNode): Boolean;
var
  ChildCount, I: LongWord;
begin
  if ts_node_type(Node) = 'kRaise' then
    Exit(True);
  Result := False;
  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    if SubtreeHasRaise(ts_node_child(Node, I)) then
      Exit(True);
    Inc(I);
  end;
end;

// `try`ノードが「エラーを実際に処理する」except節を持つか。
// finallyのみのtryは保護とみなさない(冒頭コメント参照)。
//
// さらに、except節の中で例外を送出(`raise;`による再送出や、別の例外への
// 詰め替え)している場合も保護とみなさない。fpc-source全体に当てた実測で
// 最大の誤検知要因がこれだった: `try ... except FreeAndNil(Result); Raise;
// end;` はPascalで極めて一般的な「失敗時に後始末して呼び出し元に投げ直す」
// 定型であり、try-finallyと同じく後始末であってエラー処理ではない。これを
// 「保護されている」と数えると、同じAPIを素直に呼んでいる他の箇所が
// 軒並み「未保護」として報告されてしまう(fpsqlparser.pasで12件)。
// 別種の例外へ詰め替えるケースまで巻き込んで抑制することになるが、
// CLAUDE.mdルール5(疑わしきは見逃す)に従い広めに抑制する。
function TryHasHandlingExcept(const Node: TSNode): Boolean;
var
  ChildCount, I: LongWord;
  ExceptChild: TSNode;
  Found: Boolean;
begin
  Result := False;
  Found := False;
  ChildCount := ts_node_child_count(Node);
  I := 0;
  while I < ChildCount do
  begin
    if ts_node_field_name_for_child(Node, I) = 'except' then
    begin
      ExceptChild := ts_node_child(Node, I);
      if SubtreeHasRaise(ExceptChild) then
        Exit(False);
      Found := True;
    end;
    Inc(I);
  end;
  Result := Found;
end;

// 引数が全て定数リテラルか(冒頭コメント(d))。引数が0個の場合はFalseを返し、
// 呼び出し元の「引数1つ以上」チェックに委ねる。
function AllArgsAreLiterals(const ArgsNode: TSNode): Boolean;
var
  NamedCount, I: LongWord;
  ArgType: PAnsiChar;
begin
  NamedCount := ts_node_named_child_count(ArgsNode);
  if NamedCount = 0 then
    Exit(False);
  I := 0;
  while I < NamedCount do
  begin
    ArgType := ts_node_type(ts_node_named_child(ArgsNode, I));
    if not ((ArgType = 'literalString') or (ArgType = 'literalNumber') or
            (ArgType = 'kTrue') or (ArgType = 'kFalse') or (ArgType = 'kNil')) then
      Exit(False);
    Inc(I);
  end;
  Result := True;
end;

// `exprCall`が監視対象の修飾なし呼び出しであれば、その識別子ノードと名前を返す。
function TryGetWatchedCall(const CallNode: TSNode; Ctx: TLintContext;
  SysUtilsUsed: Boolean; out EntityNode: TSNode; out NameUpper: string): Boolean;
var
  ChildCount, I: LongWord;
  ArgsNode: TSNode;
  HasEntity, HasArgs: Boolean;
begin
  Result := False;
  HasEntity := False;
  HasArgs := False;
  EntityNode := CallNode; // ダミー初期値
  ArgsNode := CallNode;

  ChildCount := ts_node_child_count(CallNode);
  I := 0;
  while I < ChildCount do
  begin
    if ts_node_field_name_for_child(CallNode, I) = 'entity' then
    begin
      EntityNode := ts_node_child(CallNode, I);
      HasEntity := True;
    end
    else if ts_node_field_name_for_child(CallNode, I) = 'args' then
    begin
      ArgsNode := ts_node_child(CallNode, I);
      HasArgs := True;
    end;
    Inc(I);
  end;

  // 修飾付き呼び出し(entityがexprDot)は対象外(冒頭コメント(c))。
  if not (HasEntity and (ts_node_type(EntityNode) = 'identifier')) then
    Exit;
  // 引数が1つ以上あることを要求する(冒頭コメント(c))。
  if not (HasArgs and (ts_node_named_child_count(ArgsNode) > 0)) then
    Exit;
  if AllArgsAreLiterals(ArgsNode) then
    Exit;

  NameUpper := UpperCase(Ctx.GetNodeText(EntityNode));
  Result := IsWatchedApi(NameUpper, SysUtilsUsed);
end;

procedure AddProtectedName(var Res: TScanResult; const NameUpper: string);
begin
  if ContainsName(Res.ProtectedNames, NameUpper) then
    Exit;
  SetLength(Res.ProtectedNames, Length(Res.ProtectedNames) + 1);
  Res.ProtectedNames[High(Res.ProtectedNames)] := NameUpper;
end;

procedure AddUnprotectedSite(var Res: TScanResult; const NameUpper, NameText: string;
  const Node: TSNode);
begin
  SetLength(Res.UnprotectedSites, Length(Res.UnprotectedSites) + 1);
  Res.UnprotectedSites[High(Res.UnprotectedSites)].NameUpper := NameUpper;
  Res.UnprotectedSites[High(Res.UnprotectedSites)].Node := Node;
  Res.UnprotectedSites[High(Res.UnprotectedSites)].NameText := NameText;
end;

// 保護状態を伝播させながら木を1回だけ走査し、監視対象呼び出しを集計する。
procedure Scan(const Node: TSNode; Ctx: TLintContext; State: TProtectionState;
  var Res: TScanResult);
var
  ChildCount, NamedCount, I: LongWord;
  EntityNode: TSNode;
  NameUpper: string;
  HasExcept: Boolean;
  FieldName: PAnsiChar;
  ChildState: TProtectionState;
begin
  if ts_node_type(Node) = 'exprCall' then
  begin
    if TryGetWatchedCall(Node, Ctx, Res.SysUtilsUsed, EntityNode, NameUpper) then
    begin
      if State = psProtected then
        AddProtectedName(Res, NameUpper)
      else if State = psUnprotected then
        AddUnprotectedSite(Res, NameUpper, Ctx.GetNodeText(EntityNode), EntityNode);
      // psIgnored(except/finally節の中身)はどちらにも数えない。
    end;
    // 引数の中にネストした呼び出しがありうるので走査は打ち切らない。
  end;

  if ts_node_type(Node) = 'try' then
  begin
    HasExcept := TryHasHandlingExcept(Node);
    // フィールド名を見る必要があるのでNAMEDではなく全子ノードを走査する
    // (無名トークンに監視対象呼び出しは含まれないので余計に辿っても無害)。
    ChildCount := ts_node_child_count(Node);
    I := 0;
    while I < ChildCount do
    begin
      FieldName := ts_node_field_name_for_child(Node, I);
      if (FieldName = 'try') and HasExcept then
        ChildState := psProtected
      else if (FieldName = 'except') or (FieldName = 'finally') then
      begin
        // 外側のtry-exceptに包まれているなら実際に保護されているので維持する。
        if State = psProtected then
          ChildState := psProtected
        else
          ChildState := psIgnored;
      end
      else
        // finallyのみのtryの本体を含む。保護状態は変えずそのまま引き継ぐ。
        ChildState := State;
      Scan(ts_node_child(Node, I), Ctx, ChildState, Res);
      Inc(I);
    end;
    Exit;
  end;

  NamedCount := ts_node_named_child_count(Node);
  I := 0;
  while I < NamedCount do
  begin
    Scan(ts_node_named_child(Node, I), Ctx, State, Res);
    Inc(I);
  end;
end;

function TRuleStyle002.RuleId: string;
begin
  Result := CRuleId;
end;

function TRuleStyle002.Severity: TSeverity;
begin
  Result := CSeverity;
end;

function TRuleStyle002.Description: string;
begin
  Result := 'inconsistent error handling: the same failure-prone API is called both inside and outside try..except in one file';
end;

function TRuleStyle002.InterestedNodeTypes: TStringArray;
begin
  // rootノードのみ。ファイル単位の集計(保護された名前を集めてから未保護の
  // 呼び出しと突き合わせる)が必要だが、ルールインスタンスはRuleRegistryに
  // よって複数ファイル間で使い回されるため、インスタンスフィールドに状態を
  // 持たせるとファイルをまたいで漏れる。P4(RuleDepr001.pas)で確立した、
  // 1回のCheck呼び出し内でローカル変数を使い自己完結させる設計に倣う。
  Result := TStringArray.Create('root');
end;

procedure TRuleStyle002.Check(const Node: TSNode; Ctx: TLintContext);
var
  Res: TScanResult;
  I: Integer;
begin
  SetLength(Res.ProtectedNames, 0);
  SetLength(Res.UnprotectedSites, 0);
  Res.SysUtilsUsed := FindSysUtilsInUses(Node, Ctx);

  Scan(Node, Ctx, psUnprotected, Res);

  if Length(Res.ProtectedNames) = 0 then
    Exit;

  for I := Low(Res.UnprotectedSites) to High(Res.UnprotectedSites) do
    if ContainsName(Res.ProtectedNames, Res.UnprotectedSites[I].NameUpper) then
      Ctx.Report(CRuleId, CSeverity,
        Format('"%s" is wrapped in try..except elsewhere in this file but not here; ' +
               'error handling for this API is inconsistent within the file',
               [Res.UnprotectedSites[I].NameText]),
        Res.UnprotectedSites[I].Node);
end;

initialization
  RegisterRule(TRuleStyle002.Create);

end.
