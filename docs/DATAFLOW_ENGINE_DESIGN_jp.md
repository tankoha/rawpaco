# 制御フローグラフとデータフロー解析エンジン: 設計

- 作成日: 2026-11-17
- 位置づけ: 設計ドキュメント（実装は未着手。ソースコードは一切変更していない）。14章にオーナーが回答するまで、本書の内容は何も決定ではない
- 対象: rawpaco は commit `cc224b2` 時点、tree-sitter-pascal は vendoring 済みの v0.10.2
- 言語について: 英語版 `docs/DATAFLOW_ENGINE_DESIGN.md` が正（canonical）。本書は参照用の日本語版で、更新は英語版を先に行う（HANDOFF.md の規約）
- 関連: [RULE_ENGINE_DESIGN_jp.md](RULE_ENGINE_DESIGN_jp.md) の 0章・2.3節・2.8節（構文だけでは答えられないこと、MEM ルール）、[OPENGREP_RULE_ENGINE_DESIGN_jp.md](OPENGREP_RULE_ENGINE_DESIGN_jp.md) の 2.7節と未決事項 12（taint の簡易版）

本書では opengrep の検討書と同じく、根拠の強さを次の3つで書き分ける。

- **【実測】** この検討で実際に何かを実行して確認したこと（内容は付録）
- **【ソース確認】** rawpaco のソースまたは vendoring した文法を読んで確認したこと
- **【未確認】** 既知の知識または推測。実装前に裏取りが必要なこと

---

## 0. 要約

**方向性（オーナー提案）:** パースの土台は tree-sitter-pascal のままにし、rawpaco 自前の小さく明示的な制御フローグラフ（CFG）とデータフロー解析エンジンを作る。後で手続き間解析へ伸ばせる形に最初からしておく。

**評価: 実現可能。3段構成も妥当である。ただし出発点の案に4点の修正が要る。**

1. **IR は平坦な命令列ではなく、構造を持つ必要がある。** IR が「def/use 付きの文の並び」だけだと、制御構造は tree-sitter の木に残ったままになり、CFG の構築で木の形をもう一度読むことになる。本書の IR は正規化した小さな文の木（約15種類）で、葉に「変数の出現」を分類して持たせる。tree-sitter-pascal の木の形に関する知識は、変換を担当する1ユニットに閉じ込める。式は三番地コードに分解**しない**（3章）。
2. **「解析不能」の段階は1つではなく2つ要る。** 現行の MEM ルールは、`with` や `{$ifdef}` を含むルーチンでも判定を続けている（関係する変数だけを諦める）。「解析不能」がどの段階でもルーチン全体を黙らせるなら、MEM-001/002 を新エンジンに載せ替えた時点で既存の真陽性が失われる。そこで、IR（出現の事実）はほぼ全ルーチンについて作り、CFG はより厳しい門番を通ったルーチンだけに作る（5章）。
3. **「MEM-001/002 を CFG 上に再実装し、現在の結果を回帰の基準にする」は2段階に分ける必要がある。** フローを見る MEM-002 は現行より**精密**なので、結果は基準と両方向に正当にずれる。第1段階は、IR の事実から現行の出力をバイト単位で再現する「同値移植」とする（変換の正しさを検証できる）。第2段階がフローを見る版で、基準との差分は1件ずつ分類して確認する（9章）。
4. **実測で見つかった3つの構文について、出発点の一覧に無い判断が要る**（4.3節）。
   - `Exit`・`Break`・`Continue`・`Halt` はこの文法ではキーワードではない。普通の識別子なので、ジャンプは名前で見分けることになり、同名の宣言で隠されうる。
   - 条件コンパイル指令は tree-sitter の「extras」である。`{$ifdef A} X; {$else} Y; {$endif}` は、木の上では `X; Y;` という直列の並びになる。そのまま CFG を作ると、どのビルドにも存在しない経路ができる。
   - 後ろに `;` の無い裸の `raise`（`raise end` や `raise else`）は、キーワードを識別子として飲み込んだ `raise <式>` としてパースされる。周囲の構造は壊れるが、その場所に `ERROR` ノードは出ない。

**規模（見積もり、精度は低い）:** マイルストーン F1〜F5（IR、CFG、ソルバ、解析3種、MEM の2段階）で Pascal 2,700〜3,700 行（テストを除く）。オーナーの見積もり 1,500〜3,000 行は、エンジン単体（F1〜F3: 約 1,900〜2,500 行）については妥当である。比較のため: `src/` は現在 7,359 行【実測】、opengrep の `src/analyzing` は OCaml で 9,415 行、IL が 1,956 行（opengrep 検討書の記録による）。

**適用できる範囲（手元の FPC ソースツリーで実測、4.4節）:** ルーチンの 90.3%（148,646 件中 134,266 件）が CFG の門番を通る。外れる理由で多いのは、アセンブラルーチン（4.3%）、本体内の条件コンパイル（3.3%）、`with`（1.6%）である。

**都合の悪い副次的な発見:** このツリーでは、ファイルの 58% がどこかに構文エラーを1つ以上含み、現行の MEM ルールはそういうファイルを丸ごと飛ばしている。この門番を「ファイル単位」から「ルーチン単位」に緩めるかどうかは、誤検知のリスクを伴う別の判断である（13章のリスク6、未決事項4）。

---

## 1. 目標と対象外

### 1.1 目標

- ルーチンごとの CFG。Pascal の通常でない制御の流れ（`try..finally`、`try..except`、`raise`、`Exit`、`Break`、`Continue`）を明示的に表す。
- 汎用の単調データフローソルバと、最初の解析3種: 到達定義、生存変数、オブジェクト状態（「確実に解放済み／解放済みかもしれない」）。
- ルールは木の形ではなく事実を使う。ルールは「このオブジェクトは正常終了に至る全経路で生きているか」を問い、自分で `try` ノードを辿らない。
- 確信が無ければ黙る（CLAUDE.md ルール5）。エンジンが正確にモデル化できないルーチンからは、フローに基づく検知を出さない。閉じた設計とする: 変換が受け付けるノード種別は固定の一覧で、それ以外が現れたルーチンは解析不能にする。
- 後で関数サマリを置ける場所。サマリはルーチンの IR に付けるので、手続き間解析の段階で増えるのはデータであり、新しい表現ではない。
- 宣言的ルール層（`src/Decl/`、M1 実施中）とは独立に保つ。共有するのはビルドの配線だけである。

### 1.2 対象外

- SSA、三番地コード、定数伝播、エイリアス解析、ポインタ解析は行わない。
- 型推論は行わない。シンボルテーブルも「この名前はこのルーチンのローカルである」以上のものは持たない。RULE_ENGINE_DESIGN の 0章の制約はそのまま残る。
- opengrep 互換の taint モードは作らない。rawpaco 独自の簡易 taint を後でこのエンジンの上に作る可能性はあるが、`mode: taint` とは名付けない（11章）。
- 本書で計画するマイルストーンでは、ユニット間・プログラム全体の解析は行わない（必要になるものは 10章）。
- コンパイラが挿入するコード（管理型のための暗黙の `try..finally`、インターフェース参照や文字列の暗黙の後始末）はモデル化しない。
- 健全性を目指す検証器ではない。健全性と「黙ること」がぶつかる箇所では、黙る方を選ぶ。

---

## 2. アーキテクチャ

```
tree-sitter の CST（ファイル単位、既存）
   │  FlowLower   tree-sitter-pascal のノードの形を知る唯一のユニット
   ▼
ルーチン IR     構造を持つ文の木 + 分類済みの変数の出現 + 呼び出し箇所
   │  FlowCfg     IR だけを知る。CFG の門番を通らないルーチンは拒否する
   ▼
CFG             単純な命令1つにつき1ノード、種別付きの辺、出口は2つ（正常／例外）
   │  FlowSolve   ビット集合の事実に対するワークリスト型ソルバ、辺種別のマスク
   ▼
事実            到達定義、生存変数、オブジェクト状態
   │
   ▼
ネイティブルール（最初は MEM-001/002）      後で: サマリ、宣言的ルール層へのフック
```

新設する `src/Flow/` 配下のユニット案（`src/Decl/` のときと同じく、`Makefile` の `-Fusrc/Flow`・`RULE_SOURCES`・`selflint`・`clean` と、Windows CI の `fpc` 呼び出しへの追加が要る）:

| ユニット | 内容 | 依存先 |
|---|---|---|
| `FlowIR.pas` | IR の型定義のみ | TSBindings |
| `FlowLower.pas` | CST → IR、解析不能の理由 | FlowIR、ASTHelpers |
| `FlowCfg.pas` | IR → CFG、不変条件の検査 | FlowIR |
| `FlowDump.pas` | IR のテキストダンプ、CFG の DOT ダンプ | FlowIR、FlowCfg |
| `FlowBits.pas` | 固定長のビット集合 | — |
| `FlowSolve.pas` | ワークリスト型ソルバ | FlowCfg、FlowBits |
| `FlowAnalyses.pas` | 到達定義、生存変数、オブジェクト状態 | FlowSolve |
| `FlowCache.pas` | ルールに渡すファイル単位の遅延キャッシュ | 上記すべて |

`FlowBits` と `FlowSolve` は tree-sitter に依存しないので、`PatLexer` と同じ形（`tests/unit/Test<Unit>.lpr`）で単体テストできる。

---

## 3. ルーチン IR

### 3.1 この形にする理由

- **構造を持つ。** IR は `if`・ループ・`case`・`try` を木のノードとして残す。こうすると CFG の構築に tree-sitter の知識が要らず、後のサマリ計算も構造（たとえば「この解放は `finally` の中か」）を使える。
- **文の粒度。** 単純な文または条件1つにつき葉を1つ。Pascal は引数の評価順を規定していない【未確認: FPC リファレンスについての既知の知識】。1文の中に命令単位の順序を付けると、言語が保証しない精度を主張することになる。
- **出現は「use」「def」だけでなく分類する。** MEM ルールは `L.Free`（レシーバ）、`List.Add(L)`（引数。所有権が移りうる）、`Result := L`（値のコピー）、`L := ...`（定義）を区別している。現行の誤検知回避はこの分類に宿っているので、IR でも保存する。

### 3.2 変数

追跡するのは、ルーチンのローカルだと証明できる名前だけである。

- 仮引数（`declArg`）、ローカル変数（`local` フィールド配下の `declVars`）、インライン変数（`varDef`・`varAssignDef`）、ループ変数、`on E:` のハンドラ変数、`Result`
- ルーチン自身の名前への代入は `Result` の定義として扱う。ルーチン自身の名前のそれ以外の出現は、未知の呼び出しとして扱う

名前は大文字小文字を無視して比べる。それ以外の名前（フィールド、グローバル、プロパティ、ユニット修飾された名前）は「非ローカル」で、追跡しない。Pascal ではローカルが同名のフィールドやグローバルを必ず隠すので、これにシンボルテーブルは要らない。例外は1つで、`with` の本体では裸の名前が `with` の対象のメンバかもしれない。`with` が CFG の門番を通らない理由はこれである。

次の場合、変数に印を付け、すべての解析で「不明」として扱う。

- ネストした手続きまたは無名関数の中で参照されている（`vfCaptured`）
- `@` でアドレスを取られている（演算子が `kAt` の `exprUnary`【実測】）（`vfAddressTaken`）
- `absolute` 付きで宣言されている、または他の変数がその変数に `absolute` で重ねられている【ソース確認: `grammar.js` の `declVar`】（`vfAbsolute`）
- インライン変数の名前が、同じルーチンの他の変数と衝突している（区別にはブロックスコープの解決が要る）

### 3.3 宣言（スケッチ）

```pascal
type
  TVarId = Integer;                       // index into TRoutineIR.Vars; -1 = non-local
  TVarKind = (vkParam, vkLocal, vkInlineVar, vkResult, vkLoopVar, vkHandlerVar);
  TVarFlag = (vfCaptured, vfAddressTaken, vfAbsolute, vfByRefParam);
  TVarInfo = record
    NameUpper: string;
    Kind: TVarKind;
    Flags: set of TVarFlag;
    TypeText: string;                     // declared type as written; '' if not a simple typeref
    DeclNode: TSNode;
  end;

  // How a tracked variable appears in an instruction.
  TOccKind = (
    okDef,        // whole-variable assignment target:  L := ...
    okUpdate,     // read and written:  L += 1
    okReceiver,   // L.<member>  (Member holds the member name)
    okArg,        // bare argument of a call:  Foo(L)  (CallIndex, ArgIndex set)
    okNilTest,    // Assigned(L), L = nil, L <> nil
    okValue);     // any other read:  X := L, A[L], L + 1, with L do
  TOccurrence = record
    VarId: TVarId;
    Kind: TOccKind;
    Member: string;
    CallIndex, ArgIndex: Integer;
    Node: TSNode;
  end;

  TCallShape = (csPlain, csMethod, csInherited, csBareStatement, csConstructor);
  TCallSite = record
    Shape: TCallShape;
    CalleeUpper: string;                  // last identifier of the callee
    ReceiverVar: TVarId;                  // for L.Foo(...); -1 otherwise
    ArgCount: Integer;
    Node: TSNode;
  end;

  // Why an instruction may raise. Ordered from weakest to strongest evidence.
  TRaiseClass = (rcNone, rcImplicit, rcCall, rcExplicit);

  TInstrKind = (ikAssign, ikExprStmt, ikCond, ikCaseSelector,
                ikForInit, ikForTest, ikForStep, ikForDone,
                ikForInInit, ikForInNext,
                ikRaise, ikReraise, ikExit, ikBreak, ikContinue, ikNoReturn,
                ikHandlerBind, ikOpaque);
  TInstr = record
    Kind: TInstrKind;
    Node: TSNode;                         // for positions and messages
    Occs: array of TOccurrence;
    Calls: array of TCallSite;
    RaiseClass: TRaiseClass;
  end;

  TStmtKind = (skInstr, skSeq, skIf, skWhile, skRepeat, skFor, skForIn, skCase,
               skTryFinally, skTryExcept, skWith, skGoto, skLabel, skAsm);
  TStmt = class
    Kind: TStmtKind;
    InstrIndex: Integer;                  // skInstr: index into TRoutineIR.Instrs
    Children: array of TStmt;             // meaning depends on Kind (documented per kind)
    HandlerCatchesAll: Boolean;           // skTryExcept
    Node: TSNode;
  end;

  TGateReason = (grNone, grSyntaxError, grKeywordAsRaiseOperand, grUnknownNodeType,
                 grMacroFile, grAsmBody,                       // IR gate (no IR at all)
                 grWith, grGotoLabel, grAsmStatement, grConditionalDirective,
                 grIncludeDirective, grShadowedJumpName, grJumpOutsideLoop,
                 grJumpInFinally, grTooLarge);                 // CFG gate (IR exists)
  TRoutineIR = class
    Name: string;
    Node: TSNode;                         // the defProc or lambda
    Vars: array of TVarInfo;
    Instrs: array of TInstr;
    Body: TStmt;
    Nested: array of TRoutineIR;          // nested procedures and anonymous functions
    IRGate, CfgGate: TGateReason;
  end;
```

`ikOpaque` は、出現を見えるようにする目的だけで IR に残す文（たとえば `with` の対象の並び）に使う。

### 3.4 例外送出の分類

型が無いと、Pascal のほぼすべての文が例外を出しうる。メンバアクセスはプロパティの getter かもしれず、算術はオーバーフローしうるし、参照外しは落ちうる。そういう文すべてに同じ重みの例外辺を張ると、「例外経路で漏れうるか」を問うルールの答えは常に「はい」になる。そこで各命令に「例外を出しうる根拠のうち最も強いもの」を記録し、どの分類まで辿るかは解析ごとに選ぶ。

| 分類 | 命令が次を含むとき | 辺の種別 |
|---|---|---|
| `rcExplicit` | `raise` 文、または `Abort` の呼び出し | `ekRaise` |
| `rcCall` | `exprCall`、裸の識別子だけの文、文の位置の `exprDot`、`inherited`、`for..in` の1歩（列挙子の呼び出し） | `ekMayRaiseCall` |
| `rcImplicit` | 式の位置の `exprDot`（プロパティの getter かもしれない）、`as`、`^`、添字、`div` / `mod` | `ekMayRaiseImplicit` |
| `rcNone` | 上のどれも含まない | 辺なし |

誤検知を出してはならないルールは `ekRaise` と `ekMayRaiseCall` だけを辿る。経路を多めに見積もる必要があるルール（たとえば「全経路で解放済み」を証明する場合）は3種とも辿る。

---

## 4. tree-sitter-pascal から IR へ

### 4.1 ノードの形（注記が無いものはすべて、v0.10.2 に対するダンプ用プローブでの【実測】）

| 構文 | 木の形 | 変換時の注意 |
|---|---|---|
| ルーチン | `defProc`。フィールドは `header`（`declProc`）、`local`（multiple: `declVars`・`declConsts`・`declLabels`・ネストした `defProc`）、`body`（`block` または `asm`） | メソッド名は `genericDot`、演算子は `operatorName` |
| プログラムのメインブロック | `program` 直下の `block` | F1〜F5 ではルーチンとして扱わない（未決事項12） |
| 文の並び | `block`（`begin..end`）と `statements`（`try`・`repeat` の本体）。子は位置で並び、フィールド名は無い | 両方を扱う必要がある（HANDOFF.md に記録済みの罠） |
| 代入 | `assignment`。`lhs`・`operator`・`rhs`。演算子は `kAssign`・`kAssignAdd`・`kAssignSub`・`kAssignMul`・`kAssignDiv` | 複合代入は `okUpdate` にする |
| 呼び出し文 | `statement` > `exprCall`（`entity`・`args`）、`statement` > `identifier`（括弧なし）、`statement` > `exprDot` | `Foo()` には `args` フィールドが無い |
| `if` | `if`（`condition`・`then`）、`ifElse`（`condition`・`then`・`else`） | `if X then else Y` は `then` フィールドの無い `ifElse` になる。空の分岐は、そのフィールドに無名トークン `;` が入る |
| `while` | `while`（`condition`・`body`） | |
| `repeat` | `repeat`（`body` は `statements`、`condition`） | |
| `for` | `for`。`start`（`assignment`）、`kTo` または `kDownto`、`end`、`body` | `for var K := ...` では `start` の `lhs` が `varAssignDef` になる |
| `for..in` | `foreach`（`iterator`・`iterable`・`body`） | `for var E in List do` はパース**できない**: `ERROR`（文法の穴） |
| `case` | `case`。セレクタは最初の名前付きの子（フィールドなし）。各分岐は `caseCase`（`label` は `caseLabel` で `range` を含みうる、`body`）。`else` 分岐には**包むノードが無く**、その文は `kElse` トークンの後ろに `case` の直接の子として並ぶ | 本体が空の分岐は `body` に `;` が入る |
| `try..finally` | `try`。フィールド `try`（`statements`。空なら無い）とフィールド `finally`（multiple: `kFinally` トークン、続いて `statements`） | |
| `try..except` | `try`。フィールド `except`（multiple）: `kExcept` トークンの後ろに、`statements` か、`exceptionHandler` の並びと省略可能な `exceptionElse` | 空の `except end` はトークンだけ |
| ハンドラ | `exceptionHandler`。`variable`（multiple: `identifier` と `:`）、`exception`（`typeref`）、`body` | `exceptionElse` にはフィールドが無く、文は位置で並ぶ |
| `raise E` | `raise`。フィールド `exception` | `raise E at Addr` は `raise` ノードの中に `ERROR` を残す |
| `raise;` | **文法が受け付けない**: extra の印が付いた `ERROR` ノードで、子は `kRaise` だけ。自分が属する場所の**直前の兄弟**として現れる。`then` / `body` の `;` トークンの前、`except` 部の（空の）`statements` の前、または `statements` / `block` の子の並びの中 | 4.3節 |
| `Exit`・`Break`・`Continue`・`Halt` | `statement` の中の普通の `identifier`、またはその識別子を `entity` とする `exprCall`（`Exit(3)`） | キーワードではない（`grammar.js` に `kExit` / `kBreak` / `kContinue` は0件【ソース確認】） |
| `with` | `with`（`entity` は multiple、`body`） | CFG の門番 |
| `goto`・ラベル | `goto` > `identifier`、文の並びの中の `label` > `identifier`、`local` の中の `declLabels` > `declLabel` | CFG の門番 |
| `asm` | `asm` > `asmBody`。文として、またはルーチンの `body` として現れる | 門番 |
| インライン変数 | `varDef`（初期値なし）が文として現れる。初期値ありは `lhs` が `varAssignDef` の `assignment` | |
| 無名関数 | `lambda`（`args`・`type`・`local`・`body`） | ネストしたルーチンとして扱う |
| ネストした手続き | 外側のルーチンの `local` フィールドにある `defProc` | ネストしたルーチンとして扱う |
| `inherited` | `inherited`（省略可能な `identifier`）。単独で `statement` に入るか、`exprCall` の `entity` になる | 呼び出し |
| アドレス取得・参照外し | `exprUnary`。`operator` は `kAt`（前置）または `kHat`（後置） | |
| `as` | `exprBinary` | |
| 指令 | `pp`。extra の印付きで、どの位置にも現れる | 4.3節 |

### 4.2 変換の規則

- 変換は閉じた一覧である。文の位置に、上の表に無い名前付きノード種別が現れたら `grUnknownNodeType` とし、そのルーチンには IR を作らない。式の位置では、識別子・呼び出し・例外送出の分類の根拠を見つければ足りるので、未知の式ノードは汎用的に辿る。
- 出現の分類は `RuleMem001` の現行の扱いに合わせる【ソース確認】。同値移植（9章）で厳密に再現できるようにするためである。宣言の名前とルーチンのヘッダは出現に数えない。代入の `lhs` の識別子は `okDef`。`exprDot` の `lhs` は `okReceiver`。`FreeAndNil` のただ1つの引数は、他の引数と同じ `okArg` とする（これを解放と判断するのは**ルール**の側）。
- ネストした手続きと無名関数は、別の `TRoutineIR` として `Nested` の下に作る。その本体は親の文の木には入れない。そこで言及された親の変数にはすべて `vfCaptured` を付ける。言及そのものも記録し、同値移植が「ネストした手続きの中で解放している」ことを引き続き見られるようにする。

### 4.3 門番

**IR の門番（IR を作らない。このエンジンからは一切の検知を出さない）:**

| 理由 | 条件 | なぜ |
|---|---|---|
| `grSyntaxError` | ルーチンの部分木に、裸の `raise` 以外の `ERROR`、または missing の印が付いたノードがある | 木がソースを反映していない可能性がある |
| `grKeywordAsRaiseOperand` | `exception` が `end`・`else`・`until` という綴りの識別子である `raise` | `raise end` / `raise else` は誤ってパースされる。キーワードがオペランドになり、囲む構造が壊れるが、その場所に `ERROR` は出ない【実測】 |
| `grUnknownNodeType` | 4.2節 | 閉じた変換。文法更新時の検出装置でもある（CLAUDE.md ルール2） |
| `grMacroFile` | ファイルが `{$MACRO` を含む | 識別子が何に展開されるか分からない。RAWPACO-HALLUC-001 と同じ理由 |
| `grAsmBody` | ルーチンの本体が `asm` | 解析する対象が無い |

**CFG の門番（IR と出現の事実は存在する。CFG は作らないので、フローに基づく検知は出さない）:**

| 理由 | 条件 | なぜ |
|---|---|---|
| `grWith` | `with` 文がある | 本体の裸の名前が、対象のメンバかもしれない |
| `grGotoLabel` | `goto`・`label`・`declLabels` がある | 構造化されていない流れ。まれなのでモデル化に見合わない |
| `grAsmStatement` | `block` の中に `asm` 文がある | 任意のジャンプとレジスタへの作用がある |
| `grConditionalDirective` | 本体の中に、テキストが `{$if`・`{$else`・`{$elseif`・`{$endif` で始まる `pp` ノードがある（`ifdef`・`ifndef`・`ifopt` を含む） | 両方の分岐が木の上では直列に並ぶ【実測】。指令は文の構造をまたぐこともある |
| `grIncludeDirective` | 本体の中に `{$I file}` / `{$include file}` がある | 文が木から欠けている |
| `grShadowedJumpName` | ルーチンが `Exit`・`Break`・`Continue`・`Halt` を文として使い、同じファイルがその名前の何かを宣言している | その文は普通の呼び出しかもしれない |
| `grJumpOutsideLoop` | ループの外で `Break` / `Continue` が文として使われている | それは組み込みのジャンプではありえない |
| `grJumpInFinally` | `finally` ブロックの中に `Exit`・`Break`・`Continue` がある | コンパイラによって合法かどうかが違う【未確認】。モデル化に見合わない |
| `grTooLarge` | CFG のノード数が固定の上限（案: 20,000）を超える | `finally` の複製による膨張を抑える |

**裸の `raise;`** は受け入れる。拒否すると、例外処理を含むコードの大半でエンジンが無効になるためである（HANDOFF.md の記録では、RAWPACO-STYLE-002 に関係するファイルの 61%）。子が `kRaise` だけの extra な `ERROR` は、その直後の場所に置く `ikReraise` 命令に変換する。これを行うのは、親が `statements`・`block`・`try`（`except` 部の中）・`exceptionHandler`・`exceptionElse`・`if`・`ifElse`・`caseCase` の場合に限る。それ以外の親の下にあれば `grSyntaxError` とする。

**残るリスク（受け入れる）:** `uses` で取り込んだユニットが `Exit`・`Break`・`Continue` という名前のルーチンを宣言している場合。1ファイルからは見えない。

### 4.4 門番を通る割合【実測】

使い捨ての集計用プローブを、手元の FPC ソースツリー（`.pas` / `.pp` 11,029 ファイル。最上位の `tests/` ディレクトリは除外）に当てて測った。**これは、記録済みの基準値を取った fpc-source 3.2.2 パッケージではない。** 同パッケージは、この検討に使った機械に入っていない。以下の数字は割合を示すもので、基準値ではない。

| 項目 | ルーチン数（`defProc`） | 割合 |
|---|---:|---:|
| 全体 | 148,646 | 100% |
| 両方の門番を通る | 134,266 | 90.3% |
| `asm`（本体または文） | 6,422 | 4.3% |
| 本体内の条件コンパイル指令 | 4,853 | 3.3% |
| `with` | 2,416 | 1.6% |
| 裸の `raise` 以外の `ERROR` | 1,670 | 1.1% |
| missing ノード | 376 | 0.3% |
| ラベル宣言またはラベル | 239 | 0.2% |
| `goto` | 75 | 0.05% |
| 本体内の `{$I}` | 68 | 0.05% |
| キーワードをオペランドにした `raise` | 2 | — |

同じ実行で得た、優先度の判断に関係する件数:

| 項目 | ルーチン数 |
|---|---:|
| `try` を含む | 8,530 |
| `Exit` / `Break` / `Continue` を使う | 17,747 |
| `case` を含む | 5,442 |
| `repeat` を含む | 1,692 |
| `for..in` を含む | 728 |
| 裸の `raise;` を含む | 642 |
| ネストした手続きを持つ | 2,404 |
| 無名関数を持つ | 31 |
| インライン変数を持つ | 105 |
| 同じ名前のローカルにコンストラクタの結果を2回以上代入している | 884 |

最後の行は、現行の MEM ルールが「生成はちょうど1回」の門番で飛ばしていて、フローを見る解析なら判定できる対象の数である。ただし上限であり、他の門番（所有者引数、エスケープ）で一部は外れる。

ファイル単位: 11,029 ファイル中 6,416 ファイル（58%）で、ルートの `ts_node_has_error` が真になる。そのうち、エラーが裸の `raise` だけのものは 322 ファイルしかない。これらのファイルには 84,653 個のルーチンがあり、うち 75,242 個は単独で両方の門番を通る。リスク6を参照。

---

## 5. CFG

### 5.1 データ構造（スケッチ）

```pascal
type
  TNodeKind = (nkEntry, nkExitNormal, nkExitRaise, nkNoReturn,
               nkInstr, nkJoin, nkExceptDispatch);
  TEdgeKind = (ekSeq, ekTrue, ekFalse,
               ekCaseArm, ekCaseElse, ekCaseNoMatch,
               ekLoopBack, ekBreak, ekContinue, ekExit,
               ekRaise, ekMayRaiseCall, ekMayRaiseImplicit,
               ekHandler, ekUnhandled);
  TEdgeKinds = set of TEdgeKind;
  // Which way a finally block was entered; fcNone for nodes outside any clone.
  TCompletion = (fcNone, fcNormal, fcRaise, fcExit, fcBreak, fcContinue);

  TCfgEdge = record
    Src, Dst: Integer;
    Kind: TEdgeKind;
  end;
  TCfgNode = record
    Kind: TNodeKind;
    InstrIndex: Integer;                  // -1 for synthetic nodes
    Completion: TCompletion;
    Succ, Pred: array of Integer;         // edge indices
  end;
  TRoutineCfg = class
    IR: TRoutineIR;
    Nodes: array of TCfgNode;
    Edges: array of TCfgEdge;
    Entry, ExitNormal, ExitRaise: Integer;
  end;
```

- **命令1つにつき1ノード。基本ブロックは作らない。** ルーチンは小さく、ソルバはブロックを必要としない。ゴールデンの DOT ファイルも読みやすく、レビューしやすい。
- **出口は2つ。** `nkExitNormal` と `nkExitRaise` を分けることで、「呼ばれるたびに漏れる」と「例外が出たときだけ漏れる」を同じグラフ上の別の問いにできる。`nkNoReturn` は `Halt` と `RunError` の行き先である。
- ノードと辺の番号は作成順に振り、構築は決定的にする。ダンプは実行ごと・プラットフォームごとに変わらない。

### 5.2 構文ごとの辺の規則

| IR の文 | 辺 |
|---|---|
| `skSeq` | 各子の正常な終わり → 次の子（`ekSeq`） |
| `skIf` | 条件 → then（`ekTrue`）。条件 → else、else が無ければ → 後続（`ekFalse`）。各分岐の終わり → 後続 |
| `skWhile` | 条件 → 本体（`ekTrue`）、→ 後続（`ekFalse`）。本体の終わり → 条件（`ekLoopBack`）。`Break` → 後続、`Continue` → 条件 |
| `skRepeat` | 本体 → 条件。条件 → 本体の先頭（`ekFalse`、後ろ向きの辺）、→ 後続（`ekTrue`）。`Continue` → 条件 |
| `skFor` | `ikForInit`（ループ変数を定義し、両端の式を使う。評価は1回）→ `ikForTest` → 本体（`ekTrue`）→ `ikForStep` → `ikForTest`（`ekLoopBack`）。`ikForTest` → `ikForDone`（`ekFalse`）→ 後続。`Continue` → `ikForStep`。`Break` → 後続（`ikForDone` を通らない）。`ikForDone` はループ変数を未定義にする。言語が正常終了後にそう定めているためである【未確認: FPC リファレンス】 |
| `skForIn` | `ikForInInit`（反復対象を使う、`rcCall`）→ `ikForInNext`（`rcCall`）→ 本体（`ekTrue`、反復変数を定義）→ `ikForInNext`（`ekLoopBack`）。`ikForInNext` → 後続（`ekFalse`） |
| `skCase` | セレクタ → 各分岐（`ekCaseArm`）。セレクタ → else 分岐（`ekCaseElse`）、else が無ければ → 後続（`ekCaseNoMatch`）【未確認: どのラベルにも一致しない場合、FPC は何もせず通過する】。各分岐の終わり → 後続 |
| `ikExit` | → 出口への継続（5.3節）。`Exit(X)` は `Result` の定義でもある |
| `ikNoReturn` | → `nkNoReturn` |
| `ikRaise`・`ikReraise` | → 現在の例外の行き先（`ekRaise`）。正常な後続は無い |
| `RaiseClass` が `rcImplicit` 以上の命令 | 現在の例外の行き先への辺を1本追加する。種別は 3.4節のとおり |
| `skTryFinally` | 5.3節 |
| `skTryExcept` | 5.4節 |

「現在の例外の行き先」は、次のうち最も内側のものである: その命令を **try 部**に含む `try..except` の振り分けノード、その命令を **try 部**に含む `finally` の例外用の複製、`nkExitRaise`。

### 5.3 `try..finally`: 継続ごとに複製する

`finally` ブロックは、`try` 部から出るすべての経路（正常終了、例外、`Exit`、`Break`、`Continue`）で実行される。2つの設計を比べた。

- **共有:** `finally` の本体を1つだけ作り、後続を複数持たせる。小さいが、入ってくる経路すべてが、出ていく経路すべてと合流する。正常に入った経路が、例外用の後続から「出ていく」ことになる。may 解析では存在しない経路ができ、それが誤検知になる。
- **複製（提案）:** 異なる**継続**（終わった後に制御が向かう先）ごとに、`finally` の本体を1つ作る。

構築時にはフレーム（`Loop`・`Finally`・`Except`・`Routine`）のスタックを持つ。ジャンプは、ジャンプの位置から目的のフレームまでスタックを外向きに辿って解決する。途中で越える `Finally` フレームごとに、（フレーム、継続ノード）をキーにした複製を取得または作成する。こうすると、同じ `try` の中の2つの `Exit` は1つの複製を共有し、同じ `try` の中の例外を出しうる命令はすべて例外用の複製を共有する。

- try 部の正常な終わり → 複製[正常] → 文の後続
- try 部の中の例外を出しうる命令 → 複製[例外] → この `try` の外側の例外の行き先
- `Exit` → 複製[exit] → 次に外側の `finally` の exit 用複製 → … → `nkExitNormal`
- `Break` / `Continue` → ループのフレームまでの複製 → ループの break / continue の行き先
- 複製の中の例外を出しうる命令 → この `try` の外側の例外の行き先

1つの命令の複製はすべて同じ `InstrIndex` を持つ。ルールは命令に対して報告するので、報告は1回になる。複製が掛け算で増えるのは `finally` ブロックの中に `try` がネストする場合だけで、これはまれである。最悪の場合はノード数の上限（`grTooLarge`）で抑える。

### 5.4 `try..except`

- try 部の中の例外を出しうる命令 → 振り分けノード `nkExceptDispatch`
- 振り分け → 各ハンドラ（`ekHandler`）。型情報が無いので、どのハンドラが一致するかは分からない。すべてのハンドラを後続の候補にする
- `on E: T do` は `ikHandlerBind` から始まる。これが `E` を定義する
- `except` 部が単なる文の並びであるか、`else` 部を持つ場合、ハンドラ群はすべての例外を捕まえる（`HandlerCatchesAll`）。そうでなければ、振り分けからこの `try` の外側の例外の行き先へ `ekUnhandled` の辺も張る。`on E: Exception do` は「すべて捕まえる」とは**扱わない**。FPC は任意のオブジェクトを raise できる【未確認】
- ハンドラの終わり → 文の後続
- ハンドラの中の `ikReraise` と例外を出しうる命令 → この `try` の外側の例外の行き先
- ハンドラから外へのジャンプは、通常どおりフレームのスタックで解決する

### 5.5 不変条件（デバッグ用の検査ルーチンとテストで確認する）

- すべての辺の両端が有効なノードである。`Succ` / `Pred` が `Edges` と一致する
- 2つの出口と `nkNoReturn` には後続が無い。それ以外のノードには後続が1つ以上ある
- すべてのノードが `nkEntry` から到達できる。そうでないものは、到達不能（`Exit` の後ろのコード）と明示されている
- `rcNone` の命令には例外辺が無い。`ikRaise` / `ikReraise` には正常な後続が無い

---

## 6. データフローの枠組み

### 6.1 事実はビット集合

ここで計画する解析はどれも「成り立つかもしれないものの集合」の問題である。そこで、事実の表現をビット集合に、合流を和集合（問題によっては積集合）に固定する。こうするとソルバをジェネリックにせずに済み、単調性が見て分かりやすくなり、束の高さがビット数で抑えられる。

このとき「確実に X」は「集合が X を含み、他を含まない」になる。may 解析1つで「確実に解放済み」と「解放済みかもしれない」の両方に答えられるのはこのためである。

```pascal
type
  TFlowDirection = (fdForward, fdBackward);
  TFlowJoin = (fjUnion, fjIntersection);

  TFlowProblem = class
    function Direction: TFlowDirection; virtual; abstract;
    function JoinKind: TFlowJoin; virtual; abstract;
    function BitCount: Integer; virtual; abstract;
    function EdgeMask: TEdgeKinds; virtual; abstract;        // edges this analysis follows
    procedure Boundary(var Fact: TBitSet); virtual; abstract; // at entry (forward) or exits
    procedure Transfer(NodeIndex: Integer; const InFact: TBitSet;
      var OutFact: TBitSet); virtual; abstract;
    // Optional refinement of the fact sent along one edge. Default: no change.
    procedure TransferEdge(EdgeIndex: Integer; var Fact: TBitSet); virtual;
  end;

  TFlowResult = class
    InFacts, OutFacts: array of TBitSet;
    Converged: Boolean;
  end;

function Solve(Cfg: TRoutineCfg; Problem: TFlowProblem): TFlowResult;
```

### 6.2 ソルバの規則

- ワークリストは、前向きなら逆後行順、後ろ向きなら後行順で初期化する。`Transfer` は単調でなければならない。これは問題を書く側の義務であり、ユニットのヘッダに明記する。
- **例外辺が運ぶのは、命令の*前*の事実である。** 例外は、命令の効果が出る前に命令を中断しうる。`L := TFoo.Create` が例外を出したとき、`L` には代入されていない。したがって前向きの問題では、`ekRaise`・`ekMayRaiseCall`・`ekMayRaiseImplicit` に沿って `OutFacts[n]` ではなく `InFacts[n]` を送る。特定の命令についてこれを変えたい問題は `TransferEdge` を使う。
- **反復回数の上限。** ソルバは、ノード訪問が `ノード数 × (BitCount + 1) × 4` 回を超えたら止まり、`Converged := False` にする。ルールは、収束しなかった結果を「解析不能」として扱わなければならない。正しい単調な `Transfer` ならこの上限には達しない。上限は、バグがハングや誤検知ではなく沈黙になるようにするためにある。
- `EdgeMask` に含まれない辺は無視する。マスクのもとで到達不能になったノードは初期の事実のままになる。

### 6.3 最初の解析

| 解析 | 向き・合流 | ビット | 用途 |
|---|---|---|---|
| 到達定義 | 前向き、和集合 | `okDef` / `okUpdate` の出現ごとに1つ。加えて変数ごとに「入口での値」を1つ | ある使用箇所がどの代入を見うるか。後の簡易 taint の土台 |
| 生存変数 | 後ろ向き、和集合 | 変数ごとに1つ | 無駄な代入の検出。後ろ向きでの枠組みの検証 |
| オブジェクト状態 | 前向き、和集合 | 候補の変数ごとに: `Unassigned`、生成箇所ごとの `Live(site)`、`Freed`、`Unknown` | MEM ルール。後で use-after-free と二重解放 |

候補の変数 `v` についての、オブジェクト状態の遷移:

- 生成 `v := T.Create` → `{Live(site)}`
- `v := nil` → `{Unassigned}`
- `v.Free`・`v.Destroy` → `{Freed}`。`FreeAndNil(v)` → `{Unassigned}`（解放したことは記録する）
- `v` のそれ以外の定義 → `{Unknown}`
- 条件が `v` の `okNilTest` 1つだけである場合、その `ekTrue` / `ekFalse` の辺で `TransferEdge` がありえない状態を取り除く（`Assigned(v)` の真の辺では `Unassigned` を落とし、偽の辺では `Unassigned` だけを残す）。これが無いと、`if Assigned(L) then L.Free` が「解放を通らない経路」に見える
- 解放する命令の例外辺は、命令の*後*の状態を運ぶ。そうしないと、すべての `L.Free` が「`L` がまだ生きている例外経路」を作ってしまう

3.2節の印が1つでも付いた変数と、ルーチン内のどこかに `okArg` / `okValue` の出現がある変数は、候補にしない。最初の版では、エスケープの判定を意図的にフローを見ないままにする。現行で最も強い誤検知の門番を、そのままの形で保つためである。

---

## 7. ルールからの使い方

- `TLintContext` に、遅延生成する `TFlowCache` をファイルごとに1つ持たせる【ソース確認: コンテキストはファイルごとに作られ、木を消す前に解放される。したがって IR が持つ `TSNode` は有効なままである】。有効なルールが要求しない限り、何も構築しない。
- ルールは現行どおり `InterestedNodeTypes = root` とし、インスタンスに状態を持たない。
- キャッシュはルーチンごとに次を渡す: IR（または IR の門番の理由）、CFG（または CFG の門番の理由）、解いた解析（問題のクラスごとにメモ化）。これで MEM-001 と MEM-002 は1回の解析を共有できる。現在は2つのルールがそれぞれ全走査を行っている【ソース確認】。
- ルールを書く側との取り決め:
  1. 門番の理由がある場合、または `Converged = False` の場合、そのルーチンからはフローに基づく検知を出さない。
  2. 検知は命令（`TInstr.Node`）に対して報告し、CFG のノードに対しては報告しない。こうすれば `finally` の複製で診断が重複しない。
  3. ルールは、どの種別の辺を辿るのかとその理由を、ヘッダに書く（CLAUDE.md ルール8）。
- 開発者向けの CLI オプション（`--dump-pattern` と同じ流儀）: `--dump-flow-ir <files>`（テキスト）、`--dump-cfg <files>`（DOT。ルーチンごとに `digraph` 1つ）、`--flow-stats <files>`（門番の理由別のルーチン数、ノードと辺の総数、ソルバの訪問回数）。名前は未決（未決事項11）。

---

## 8. テスト方針

- **IR のゴールデンテスト** `tests/flow/ir/*.pas` + `.expected`: 4.1節の表の1行につき小さなファイル1つ、加えて門番の理由1つにつき1つ。文法更新の検出装置であり（CLAUDE.md ルール2）、パターンコンパイルのゴールデンテストと並べて更新時のチェックリストに入れる。
- **CFG のゴールデンテスト** `tests/flow/cfg/*.pas` + `.dot.expected`: DOT ダンプのテキスト比較。実行に Graphviz は要らない。少なくとも次を含める: 5.2節の全構文、5種類の入り方それぞれでの `finally`、ネストした `try`、`try..except` の中の `try..finally` とその逆、4.3節に挙げた各親の下の裸の `raise;`、`finally` の中のネストしたループの中の `Exit`。
- **事実のゴールデンテスト** `tests/flow/facts/`: 3つの解析について、ノードごとの入口・出口の集合をダンプする。
- **単体テスト** `tests/unit/TestFlowBits.lpr`、`TestFlowSolve.lpr`（手で組んだグラフ。可約でないグラフと、上限を働かせるための意図的に単調でない `Transfer` を含む）。
- **コーパスでの不変条件の確認:** fpc-source 全体に対し、不変条件の検査を有効にして `--flow-stats` を実行する。クラッシュなし、不変条件の違反なし、すべての求解が収束すること。エンジンあり・なしの実行時間を記録する。
- **コンパイラを答え合わせに使う（任意。どの程度一致するかは【未確認】）:** 事実のゴールデン用サンプルについて、生存変数と到達定義を、FPC 自身の「does not seem to be initialized」「assigned but never used」の注記と比べる。
- **ルールのサンプル:** MEM-001/002 の挙動を変えるたび、また新しいルールを足すたびに、positive と negative の両方が要る（CLAUDE.md ルール3）。新たに判定できるようになる場合（複数回の生成、再代入、条件付きの生成）にも、それぞれ両方を用意する。
- **実コードでの回帰:** 9章。
- **CI:** 上記すべてを Linux と Windows で実行する（ルール7）。Windows は 32bit ビルドである。ノードとビットの添字は `Integer` とし、`ASTWalker.pas` に書かれた `LongWord` のループカウンタの罠は `FlowLower` のすべての木の走査に当てはまる。

---

## 9. エンジン上の MEM-001/002

### 第1段階: 同値移植（F4）

現行の判定手順を、CFG を使わずに IR の出現の事実の上で書き直す。数えるのは、生成の回数、解放の回数、「保護された」解放（`skTryFinally` / `skTryExcept` のハンドラ配下）の回数、ネストしたルーチン内の解放の回数、エスケープの有無である。ファイル単位の構文エラーの門番は、この段階では残す。

**完了条件:** `tests/`、rawpaco 自身のソース、基準コーパス（HANDOFF.md: fpc-source 3.2.2、4,894 ファイル、MEM-001 = 10、MEM-002 = 48）に対して、出力が現行バイナリと3つの出力形式すべてでバイト単位に一致すること。手順は、HANDOFF.md に記録された `ASTHelpers` 切り出しのときのもの（`git worktree` で作った旧バイナリを使い、シンボルデータが見つかるようにリポジトリルートで実行する）を使う。

この段階が証明するのは変換の正しさであって、CFG ではない。その価値は、以後に出る差分が、木の読み違いではなくフローを見るロジックに由来すると分かることにある。

### 第2段階: フローを見る版（F5）

CFG の門番を通るルーチンについて、回数の代わりにオブジェクト状態の事実を使う。

| ルール | フローを見る条件 | 辿る辺 |
|---|---|---|
| MEM-001 | ある生成箇所について、そこからの**すべての**正常経路で `nkExitNormal` において `Live(site)` のままである。または、確実に生きている間に別の定義で上書きされる | 正常な辺のみ |
| MEM-002 | MEM-001 に当たらず、かつ `Live(site)` が `nkExitRaise` に到達する | 正常な辺 + `ekRaise` + `ekMayRaiseCall` + `ekHandler` + `ekUnhandled` |

CFG の門番を通らないルーチンは、第1段階のロジックのままにする。

基準からの差分として予想されるもの（いずれも実測で確認する）:

- **MEM-001 の新規検知:** 1つの変数に複数回生成し、そのうち1つを解放していない場合。生きている間に上書きされる生成。
- **MEM-002 から消える検知:** 生成と解放の間に呼び出しが1つも無い場合（例外が出るとは考えにくい）。現行の検知の中で最も役に立たないものである。
- **MEM-002 の新規検知:** `finally` 配下に解放があるが、その `finally` が生成から解放までのコードを実際には覆っていない場合。
- **MEM-002 から消える検知:** 再送出しない `try..except` が完全に処理する例外経路。

**完了条件:** 基準コーパスでの第1段階の出力との差分をすべて列挙し、上のどれかに分類する（またはバグとして直す）。**新規**の検知はすべて読んで、真陽性と判断できていること。擁護できない新規検知は、受け入れるのではなく、ルールを絞る理由になる（ルール5）。

「正常経路の一部では解放され、他では解放されない」場合は、第2段階ではどちらのルールでも意図的に**報告しない**。これは新しい種類の検知であり、独自の ID と実測が要る（未決事項5）。

---

## 10. 手続き間解析への拡張（後日。日程は未定）

**サマリ**は `TRoutineIR` に置く。仮引数ごとに `Frees` / `Escapes` / `Defines`。ルーチンごとに `MayRaise`（例外送出の分類）、`NoReturn`、`ReturnsFreshObject`。キャプチャされた変数ごとに、親の中と同じ出現の分類。

**型なしでの呼び出しの解決**（信頼できる順）:

1. **親から呼ばれるネストした手続き。** 解決が字句的なので正確である。最初の目標とする。`vfCaptured` による一律の除外と、解放がネストした手続きの中にあるときの MEM-002 の見送りが、これで解消する。
2. **ユニットレベルのルーチンで、同じファイルにあり、名前がファイル内で一意なもの**（オーバーロードなし、ローカルに隠されていない）。
3. **同じファイルで宣言されたクラスのメソッドで、同じクラスのメソッドからレシーバなしで呼ばれ、`virtual` / `dynamic` / `override` / `abstract` と宣言されていないもの。**
4. それ以外はすべて不明: 任意のレシーバに対する `X.Foo(...)`、手続き型変数、仮想メソッド、他のユニットのもの。

サマリは、同じファイル内の呼び出しグラフの上を下から上へ計算する。再帰の輪は、最初の版では「不明」のサマリにする。

**型なしでは解消しない限界:** 仮想メソッドの呼び出しと、レシーバで修飾された呼び出し。ローカル変数の**宣言された**型のテキストは分かるが、役に立つのは、よく知られたメンバ（`Free`、`Add` など）の固定の表に対してだけである。

**ユニット間:** 拡張の候補は2つあり、どちらも現在のアーキテクチャの外にある。

- 既存の ppudump パイプライン（`tools/gen_fpc_symbols.sh`、`tools/ppudump_symbols.awk`）で、RTL と vendoring したユニットについて、引数の渡し方（`var` / `out` / `const`）と「戻らない」の印を出力する。得られるのはシグネチャであって振る舞いではない。「引数を解放する」は `.ppu` からは得られない。
- プロジェクト自身のファイルをまたぐサマリには、2パスの実行（全ファイルのサマリを作ってから lint する）が要る。現在の `RunLint` は1ファイルずつ処理し、ルールはファイルをまたぐ状態を持たない【ソース確認】。したがってこれはアーキテクチャの変更になる（未決事項9）。

---

## 11. 宣言的ルール層との関係

- F1〜F5 では、どちら向きの依存も作らない。`src/Flow/` は `src/Decl/` を使わず、逆も同じである。
- 後のフック（opengrep 層の M2 後の続行判断と、F5 の後に限る）: ローカル変数に束縛されたメタ変数に対する rawpaco 独自の条件。たとえば「この一致より前に確実に解放済み」や「パターン P に一致する箇所から代入された」（到達定義による）。キーには `rawpaco-` の接頭辞を付け、それを使うルールファイルが opengrep 互換サブセットの外にあることを見て分かるようにする。
- 手続き内の簡易 taint（opengrep 設計書の未決事項12）は、このフックと到達定義の組み合わせになる。`mode: taint` と名付けてはならない。本書ではその日程を決めない。

---

## 12. マイルストーンと担当

M0〜M4（宣言的ルール層）および P1〜P13（ネイティブルール）と混同しないよう、マイルストーン名は F0〜F7 とする。担当は `progress.md` の体制（Opus: 管制・interface・レビュー・実測、Qwen: 実装本体、オーナー: 判断）に従う。この体制が本プロジェクトにも当てはまるという前提である（未決事項1）。**Opus** と太字にした項目は、判断そのものが仕事になるものである。

| マイルストーン | 範囲 | 規模（見積もり） | 担当 | 完了条件 |
|---|---|---|---|---|
| **F0** 事前確認 | オーナーが 14章に回答する。fpc-source 3.2.2 のコーパスを復元し、現行バイナリで MEM-001 = 10 / MEM-002 = 48 を再現する。【未確認】の言語仕様（ループ後の for 変数、一致なしの `case`、`finally` の中のジャンプ）を FPC リファレンスで確認する | — | オーナー / Opus | 決定と再現した基準値を HANDOFF.md に記録 |
| **F1** IR | `FlowIR`、`FlowLower`、IR ダンプ、`--dump-flow-ir`、IR のゴールデンテスト、`src/Flow/` のビルド配線 | 800〜1,100 行 | Opus（interface、門番の規則、裸の `raise` の配置）/ Qwen（実装） | ゴールデンテストが Linux と Windows で緑。コーパスでクラッシュなし。門番の統計を記録 |
| **F2** CFG | `FlowCfg`、DOT ダンプ、`--dump-cfg`、`--flow-stats`、不変条件の検査、CFG のゴールデンテスト | 700〜900 行 | **Opus**（`try..finally` の複製、フレームのスタック）/ Qwen（単純な構文、ダンプ） | ゴールデンテストが緑。コーパスで不変条件の違反ゼロ |
| — | **続行判断（オーナー）:** 実コードで解析できる割合は、続けるに足るか | | オーナー | |
| **F3** ソルバと解析 | `FlowBits`、`FlowSolve`、到達定義、生存変数、事実のダンプ、単体テスト | 400〜500 行 | Opus（interface）/ Qwen（実装） | 事実のゴールデンテストが緑。コーパスですべての求解が収束 |
| **F4** MEM の同値移植 | 9章の第1段階。`FlowCache` | 400〜500 行（690 行の `RuleMem001.pas` の大半を置き換える） | Opus / Qwen | テスト・自身のソース・基準コーパスで出力がバイト単位に一致 |
| **F5** フローを見る MEM | 9章の第2段階。オブジェクト状態の解析。新しいサンプル | 400〜700 行 | **Opus** | F4 との差分を分類済み。新規検知をすべて真陽性と判断済み |
| — | **続行判断（オーナー）:** サマリへ進むか。新しいルール ID を作るか | | オーナー | |
| **F6** 同一ファイル内のサマリ | 10章。ネストした手続きから | 800〜1,200 行 | Opus | F5 の後に定める |
| **F7** 宣言的ルール層へのフック、簡易 taint | 11章 | — | — | 日程未定 |

F1〜F5 の合計: テストを除いて **2,700〜3,700 行**。F1〜F2 は宣言的ルール層の M1〜M2 と並行できる。共有するファイルは `Makefile`、`.github/workflows/ci.yml`、`rawpaco.lpr` のオプション解析だけである。

---

## 13. リスク

1. **ジャンプを名前で見分けている。** `Exit`・`Break`・`Continue`・`Halt` は識別子である。同じファイル内で隠される場合は門番で止めるが、他のユニットによる場合は検出できない。
2. **「例外を出しうる」の定義が MEM-002 の精度を決める。** 狭すぎれば本物のリークを見逃し、広すぎれば保護されていない解放をすべて報告する。例外送出の分類によってルールごとに選べるようにはしたが、その選択は実測で調整するしかない。
3. **条件コンパイルは構造として見えない。** 門番が扱うのは、ルーチン本体の中の指令である。ルーチン全体を**囲む**指令があると、1つのルーチンに対して `defProc` ノードが2つできうる。それぞれ単独で解析されるので手続き内のルールには害が無いが、同一ファイル内のサマリ（F6）では問題になる。
4. **`finally` の複製でノードが増えうる**（`finally` の中に `try` がネストする場合）。ノード数の上限で抑える。上限の値は、F2 で実際の大きさを測るまでは推測である。
5. **型が無い。** プロパティの setter は呼び出しである。`var` / `out` 引数はエンジンから見えない定義である（そのため裸の引数はすべてエスケープとして扱う）。演算子はオーバーロードされうる。本設計はこれらすべてに「候補にしない」で答える。失うのは検知であって、正しさではない。
6. **構文エラーの門番。** 現在の MEM-001/002 は、どこかに構文エラーがあるファイルを丸ごと飛ばす。実測したツリーでは、これはファイルの 58% に当たる。ルーチン単位の門番にすれば、対象はおよそ2倍になる（エラーの無いファイルのルーチン 63,993 個 → 門番を通るルーチン 134,266 個）。しかし tree-sitter のエラー回復は `ERROR` ノードの外の木も歪めうるし、`raise end` の例は、その場所に何の印も無い誤パースがあることを示している。したがって門番の緩和は、移植の一部ではなく、F5 の後に実測を伴って行う独立した段階とする。
7. **費用対効果。** F1〜F5 は `src/` の規模を 35〜50% 増やす。最初に目に見える成果は、既にある2つのルールが多少精密になることである。エンジンが引き合うのは、フローを見るルール（use-after-free、二重解放、一部経路でのリーク、簡易 taint）が後に続く場合に限る。続行判断の区切りを2つ置いたのはそのためである。
8. **小さなローカルモデルが書く、間違えやすいグラフのコード。** `try..finally` の構築とオブジェクト状態の遷移は、「ほぼ正しい」ものを書いてしまいやすい。これらは Opus の担当とし、残りは不変条件の検査とゴールデンテストで捕まえる。
9. **文法のバージョン固定。** 文法の更新で、木の形が黙って変わりうる。閉じた変換は、未知の形を `grUnknownNodeType`（沈黙）に変える。何が変わったかは IR のゴールデンテストが示す。
10. **性能。** 未計測。現在はパースが支配的である（集計用プローブは 11,029 ファイルに対し、単一スレッドでパースと走査1回に約 78 秒かかった）。CFG の構築はルーチンの大きさに対して線形で、事実は小さい。フローを使うルールが有効でない限り、キャッシュは何も構築しない。

---

## 14. オーナーへの未決事項

1. **着手の可否、時期、体制。** F0〜F2 を宣言的ルール層の M1〜M2 と並行して今始めるか、M2 後の続行判断の後にするか。`progress.md` の Opus + Qwen の体制を適用するか。
2. **進捗の管理。** `progress.md` は宣言的ルール層に限定されている。そこに節を足すか、本プロジェクト用に別ファイルを作るか。
3. **基準コーパス。** この検討に使った機械には fpc-source 3.2.2 が入っておらず、記録済みの 10 / 48 を再現できなかった。入れ直すか。また、差分を取るために基準の出力をどこか（リポジトリの外）に保存しておくか。
4. **構文エラーの門番。** ファイル単位のままにするか、F5 の後に実測を伴う段階としてルーチン単位への緩和を計画するか（リスク6）。
5. **新しい種類の検知と ID。** 一部経路でのリーク（正常経路の一部でだけ解放される）、use-after-free、二重解放。新しい ID（`RAWPACO-MEM-003`…）にするか、重要度はどうするか。あるいは当面どれも作らないか。
6. **MEM-002 の意味が変わりうる。** 第2段階では、生成と解放の間に例外を出しそうなものが無い検知が消え、`finally` が生成を覆っていない検知が増える。記録済みの 48 は、分類済みの差分を伴って変わる。これを受け入れるか。
7. **`with`。** 提案: CFG の門番（ルーチンの 1.6%）。後日の代替案: CFG は作り、`with` の本体で言及されたローカルをすべて「不明」として扱う。
8. **本体内の条件コンパイル。** 提案: CFG の門番（ルーチンの 3.3%。アプリケーションのコードでは RTL より少ないと思われる）。後日の代替案: 文の並びの階層で正しく入れ子になった `{$if}…{$else}…{$endif}` を、非決定的な分岐としてモデル化する。
9. **ファイルをまたぐサマリ。** 2パスで全体を処理するモードを原則として認めるか、rawpaco は厳密にファイル単位のままにするか。
10. **簡易 taint（opengrep 設計書の未決事項12）。** 「後日このエンジン経由で、`rawpaco-` のキーで実現しうる」と記録するか、完全に未決のままにするか。
11. **開発者向けの CLI オプション。** 名前（`--dump-flow-ir`、`--dump-cfg`、`--flow-stats`）。また、ルーチンが飛ばされた理由を利用者が見られるようにするか。
12. **「ルーチン」の範囲。** F1〜F5 では `defProc` と無名関数だけ（提案）にするか、プログラムのメインブロックと `initialization` / `finalization` 部も含めるか。
13. **`finally` の方式。** 継続ごとの複製（提案）か、共有の1つか。

---

## 付録: この検討で行ったこと

- `CLAUDE.md`、`HANDOFF.md`、`progress.md`、既存の設計書2本、`src/Rules/RuleMem001.pas`、`src/ASTWalker.pas`、`src/ASTHelpers.pas`、`src/Decl/` 配下の interface、`src/LintDriver.pas`、`src/Diagnostics.pas`、`Makefile`、`vendor/tree-sitter-pascal/grammar.js` の文の規則を読んだ。
- 使い捨ての木ダンププログラム（FPC。ビルド済みの `build/*.o` にリンク。リポジトリ外のスクラッチディレクトリに置いた）を作り、4.1節の表の全行を網羅する小さなサンプル5ファイルをパースした。今後のプローブ向けの覚え書き: `{$L}` に絶対パスを書けば、プローブを `src/` の下に置く必要は無い。
- コーパスのすべての `defProc` を辿って構文と門番の理由を数える、2つ目の使い捨てプログラムを作り、手元の FPC ソースツリー（11,029 ファイル）で実行した。4.4節はこの実行による。
- 現行の `src/rawpaco` を `--only=RAWPACO-MEM-001,RAWPACO-MEM-002` 付きで同じツリーに当て、動作確認とした: 12 件と 41 件。これは記録済みの基準値とは**比較できない**（ツリーが違う）。
- 行っていないこと: `src/` と `tests/` は変更していない。rawpaco は再ビルドしていない。本書の内容を FPC リファレンスと照合していない（【未確認】の項目）。opengrep については、opengrep 検討書に記録済みの規模以外は参照していない。
