unit RuleMode002;

{$mode objfpc}{$H+}

// RAWPACO-MODE-002: 同一ファイル内で異なる `{$mode}` を宣言していることの検知
// （方言の混在）。docs/RULE_ENGINE_DESIGN.md 2.7節/P11。
//
// ■ 何が起きるか（fpc 3.2.2 で実測）
//
// `{$mode}` は「グローバルスイッチ」で、ファイルの最初の宣言より前にしか効かない。
// 2つ目以降の `{$mode}` は無視され、コンパイラは
// `Warning: Misplaced global compiler switch, ignored` を出す。つまりコード上は
// 2つのモードが書かれているのに、実際に効いているのは最初の1つだけである。
//
// 厄介なのは、同じ位置に併記されがちな `{$H+}`/`{$H-}` の方は**無視されず黙って
// 効く**点である。実測:
//
//   {$mode objfpc}{$H+} … var A: string;   {$mode delphi}{$H-} … var B: string;
//   → Warning: Misplaced global compiler switch, ignored   ({$mode delphi} のみ)
//   → Length(A)=300, Length(B)=255                         ({$H-} は効いている)
//
// unit で同じことをすると、`Error: Forward declaration not solved "F:AnsiString;"`
// のように**原因から遠いエラー**になる（interface では AnsiString、implementation
// では ShortString として解釈されて署名が食い違う）。コンパイラの警告は
// 「misplaced な指令がある」ことしか言わないので、rawpaco が
// 「このファイルは2つのモードを宣言している」と直接指せる価値がある。
//
// ■ 検知条件
//
// 条件コンパイルブロックの外（CondDepth = 0）にある `{$mode }` 指令のうち、
// **モード名が異なるもの**が2つ以上あれば、2つ目（最初に食い違ったもの）の位置で
// 報告する。
//
// ■ 誤検知回避のための門番（CLAUDE.mdルール5）
//
// (a) **条件コンパイルブロック内の `{$mode}` は数えない。**
//     `{$ifdef FPC}{$mode objfpc}{$else}{$mode delphi}{$endif}` のように
//     ビルド構成でモードを選ぶ書き方は、同時に2つが有効になるわけではない。
// (b) **同じモード名の重複は報告しない。** `{$mode objfpc}` を2回書くのは
//     冗長ではあるが方言の混在ではなく、実測でも `$H` はリセットされない
//     （2つ目が misplaced として無視されるため）。コンパイラの警告に委ねる。
// (c) **root 直下に `unit`/`program`/`library` が無いファイル（`{$i}` で
//     取り込まれる断片）は対象外。** 断片に書かれた `{$mode}` は、取り込み元の
//     モードとの関係でしか意味を判断できない。
// (d) **構文エラーを含むファイルは対象外**（指令の位置関係が信用できない）。
//
// 指令の収集・解析（`{$h+ }` のような空白、`{$H+,I-}` の並記、旧形式
// `(*$mode ...*)` が `comment` ノードになる文法の穴など）は
// `src/CompilerDirectives.pas` 側にまとめてある。

interface

uses
  SysUtils, Generics.Collections, TSBindings, Diagnostics, RuleRegistry;

type
  TRuleMode002 = class(TInterfacedObject, IRawpacoRule)
  public
    function RuleId: string;
    function Description: string;
    function Severity: TSeverity;
    function InterestedNodeTypes: TStringArray;
    procedure Check(const Node: TSNode; Ctx: TLintContext);
  end;

implementation

uses
  ASTHelpers, CompilerDirectives;

const
  CRuleId = 'RAWPACO-MODE-002';
  // 設計書4.1.2節: コンパイラ自身も `Misplaced global compiler switch` として
  // 警告を出す（＝ビルドが通らなくなるわけではない）。rawpaco の付加価値は
  // 原因を直接指すことなので、既定ではCIを落とさないWarning階層とする。
  CSeverity = svWarning;

function TRuleMode002.RuleId: string;
begin
  Result := CRuleId;
end;

function TRuleMode002.Severity: TSeverity;
begin
  Result := CSeverity;
end;

function TRuleMode002.Description: string;
begin
  Result := 'two different {$mode} directives in the same file (only the first one takes effect)';
end;

function TRuleMode002.InterestedNodeTypes: TStringArray;
begin
  Result := TStringArray.Create('root');
end;

procedure TRuleMode002.Check(const Node: TSNode; Ctx: TLintContext);
var
  Directives: TDirectiveList;
  D: TDirective;
  I: Integer;
  FirstMode: string;
begin
  if ts_node_has_error(Node) then Exit;       // 門番(d)
  if not IsCompilationUnit(Node) then Exit;   // 門番(c)

  Directives := TDirectiveList.Create;
  try
    CollectDirectives(Node, Ctx, Directives);

    FirstMode := '';
    for I := 0 to Directives.Count - 1 do
    begin
      D := Directives[I];
      if D.Kind <> dkMode then Continue;
      if D.CondDepth > 0 then Continue;       // 門番(a)

      if FirstMode = '' then
        FirstMode := D.Arg
      else if D.Arg <> FirstMode then         // 門番(b): 同名の重複は無視
      begin
        Ctx.Report(CRuleId, CSeverity,
          Format('this file already declares {$mode %s}; a second, different ' +
                 '{$mode %s} is ignored by FPC ("Misplaced global compiler switch") ' +
                 'while a {$H+}/{$H-} written alongside it does take effect',
                 [FirstMode, D.Arg]),
          D.Node);
        Exit; // 1ファイル1件で十分（同じ原因なので）
      end;
    end;
  finally
    Directives.Free;
  end;
end;

initialization
  RegisterRule(TRuleMode002.Create);

end.
