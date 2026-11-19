unit Formula;

{$mode objfpc}{$H+}

// 宣言的ルールの合成（`patterns` / `pattern-either` / `pattern-not` / `pattern-inside` /
// `pattern-not-inside`）の木と、その評価（設計書 OPENGREP_RULE_ENGINE_DESIGN 4.4）。
// 葉ごとに一致の集合（範囲と束縛）を求め、演算子で集合を組み合わせる。
//
// 集合の組み合わせ方は設計書 4.4 の表に従う。opengrep の実装には歴史的な特例があるが、
// ソースを見ながらの移植はしない方針（設計書 3章）なので、ここでは表の素直な読みを
// 実装し、M2 の差分テスト（設計書 7.3）で食い違いを洗い出す。

interface

uses
  SysUtils, TSBindings, PatCompiler, PatMatcher;

type
  TFormulaKind = (
    fkPattern,     // `pattern`。正の項
    fkPatterns,    // `patterns`。子の論理積
    fkEither,      // `pattern-either`。子の和集合。正の項
    fkNot,         // `pattern-not`。`patterns` の子にだけ現れる
    fkInside,      // `pattern-inside`。`patterns` の子にだけ現れる
    fkNotInside    // `pattern-not-inside`。`patterns` の子にだけ現れる
  );

  TFormula = class
  private
    FKind: TFormulaKind;
    FPattern: TPatCompileResult;
    FChildren: array of TFormula;
    function GetChildCount: Integer;
    function GetChild(Index: Integer): TFormula;
  public
    // fkPattern / fkNot / fkInside / fkNotInside 用。Pattern.Root の所有者はこのオブジェクト。
    constructor CreateLeaf(AKind: TFormulaKind; const APattern: TPatCompileResult);
    // fkPatterns / fkEither 用。子は AddChild で足す。
    constructor CreateNode(AKind: TFormulaKind);
    // 子と Pattern.Root を解放する。
    destructor Destroy; override;
    // 所有権を受け取る。
    procedure AddChild(Child: TFormula);
    property Kind: TFormulaKind read FKind;
    property Pattern: TPatCompileResult read FPattern;
    property ChildCount: Integer read GetChildCount;
    property Children[Index: Integer]: TFormula read GetChild;
  end;

// JSON のキー名（'pattern'、'patterns'、'pattern-either' など）。ダンプとエラー表示用。
function FormulaKeyName(Kind: TFormulaKind): string;

// fkPattern / fkPatterns / fkEither なら True（`patterns` に最低 1 つ必要な正の項）。
function IsPositiveKind(Kind: TFormulaKind): Boolean;

// A の範囲が B の範囲の中にある（両端を含む。同じ範囲も含む）なら True。
function RangeInside(const A, B: TPatMatch): Boolean;

// A と B の両方にある名前の束縛がすべて BindingsEquivalent なら True。
// 片方にしかない名前は制約にならない。
function BindingsCompatible(const A, B: TBindingArray; const Source: string): Boolean;

// A の束縛に、A に無い名前の B の束縛を足したもの（同じ名前は A を採る）。
function MergeBindings(const A, B: TBindingArray): TBindingArray;

// F を Root 以下で評価し、一致を開始バイト、終了バイトの順に並べて返す。範囲と束縛が
// まったく同じ一致は 1 件にまとめる（範囲が同じで束縛が違うものは残す。後の
// pattern-not の両立判定に効くため）。F は fkPattern / fkPatterns / fkEither のどれか。
// GoDeeperStmt は葉の照合（PatMatcher.FindMatches）にそのまま渡す。
// 一致の Deeper は合成でも引き継ぐ: 積と inside では片方でも Deeper なら Deeper
// （入れ子の中でだけ成り立つ一致なので、報告を一段下げる側に倒す）、まとめる
// ときはどれか 1 つでも Deeper でなければ Deeper でない。
function EvaluateFormula(F: TFormula; const Root: TSNode; const Source: string;
  GoDeeperStmt: Boolean): TPatMatchArray;

// ゴールデンテスト用のテキスト表現（--dump-rules）。Indent 個の空白で字下げして
// '<キー名>:' の行を書き、葉はパターンのダンプ（PatCompiler.DumpPattern）を、
// それ以外は子を、Indent + 2 で続ける。
function DumpFormula(F: TFormula; Indent: Integer): string;

// message の未束縛の参照の警告に使う。正の項と pattern-inside で束縛されうる名前を
// 重複なしで集める（pattern-not / pattern-not-inside の名前は報告に出ないので含めない）。
// pattern-either の枝は 1 つでも束縛すれば含める。
procedure CollectBoundNames(F: TFormula; var MetaVars, MetaVarEllipses: TStringArray);

implementation

constructor TFormula.CreateLeaf(AKind: TFormulaKind; const APattern: TPatCompileResult);
begin
  inherited Create;
  FKind := AKind;
  FPattern := APattern;
  FChildren := nil;
end;

constructor TFormula.CreateNode(AKind: TFormulaKind);
begin
  inherited Create;
  FKind := AKind;
  FPattern.Ok := False;
  FPattern.Root := nil;
  FPattern.ErrorMessage := '';
  FPattern.Warnings := nil;
  FPattern.MetaVars := nil;
  FPattern.MetaVarEllipses := nil;
  FChildren := nil;
end;

destructor TFormula.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FChildren) do
    FChildren[I].Free;
  if FPattern.Root <> nil then
    FPattern.Root.Free;
  inherited;
end;

procedure TFormula.AddChild(Child: TFormula);
begin
  SetLength(FChildren, Length(FChildren) + 1);
  FChildren[Length(FChildren) - 1] := Child;
end;

function TFormula.GetChildCount: Integer;
begin
  Result := Length(FChildren);
end;

function TFormula.GetChild(Index: Integer): TFormula;
begin
  Result := FChildren[Index];
end;

function FormulaKeyName(Kind: TFormulaKind): string;
begin
  case Kind of
    fkPattern:   Result := 'pattern';
    fkPatterns:  Result := 'patterns';
    fkEither:    Result := 'pattern-either';
    fkNot:       Result := 'pattern-not';
    fkInside:    Result := 'pattern-inside';
    fkNotInside: Result := 'pattern-not-inside';
  end;
end;

function IsPositiveKind(Kind: TFormulaKind): Boolean;
begin
  Result := (Kind = fkPattern) or (Kind = fkPatterns) or (Kind = fkEither);
end;

function RangeInside(const A, B: TPatMatch): Boolean;
begin
  Result := (B.StartByte <= A.StartByte) and (A.EndByte <= B.EndByte);
end;

function BindingsCompatible(const A, B: TBindingArray; const Source: string): Boolean;
var
  I, J: Integer;
begin
  Result := True;
  for I := 0 to High(A) do
  begin
    for J := 0 to High(B) do
    begin
      if A[I].Name = B[J].Name then
      begin
        if not BindingsEquivalent(A[I], B[J], Source) then
          Exit(False);
        Break;
      end;
    end;
  end;
end;

function MergeBindings(const A, B: TBindingArray): TBindingArray;
var
  I, J: Integer;
  Found: Boolean;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
  for I := 0 to High(B) do
  begin
    Found := False;
    for J := 0 to High(A) do
    begin
      if A[J].Name = B[I].Name then
      begin
        Found := True;
        Break;
      end;
    end;
    if not Found then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[Length(Result) - 1] := B[I];
    end;
  end;
end;

function Intersect(const L, R: TPatMatchArray; const Source: string): TPatMatchArray;
var
  I, J: Integer;
  M: TPatMatch;
begin
  Result := nil;
  for I := 0 to High(L) do
    for J := 0 to High(R) do
    begin
      if (RangeInside(L[I], R[J])) and
         (BindingsCompatible(L[I].Bindings, R[J].Bindings, Source)) then
      begin
        M := L[I];
        M.Bindings := MergeBindings(L[I].Bindings, R[J].Bindings);
        M.Deeper := L[I].Deeper or R[J].Deeper;
        SetLength(Result, Length(Result) + 1);
        Result[Length(Result) - 1] := M;
      end;
    end;
  // 範囲が異なる R の一致は前半で拾えないため、ここで補う
  for I := 0 to High(R) do
    for J := 0 to High(L) do
    begin
      if (RangeInside(R[I], L[J])) and
         ((R[I].StartByte <> L[J].StartByte) or (R[I].EndByte <> L[J].EndByte)) and
         (BindingsCompatible(R[I].Bindings, L[J].Bindings, Source)) then
      begin
        M := R[I];
        M.Bindings := MergeBindings(R[I].Bindings, L[J].Bindings);
        M.Deeper := R[I].Deeper or L[J].Deeper;
        SetLength(Result, Length(Result) + 1);
        Result[Length(Result) - 1] := M;
      end;
    end;
end;

function KeepInside(const P, I: TPatMatchArray; const Source: string): TPatMatchArray;
var
  Ii, Jj: Integer;
  M: TPatMatch;
begin
  Result := nil;
  for Ii := 0 to High(P) do
    for Jj := 0 to High(I) do
    begin
      if (RangeInside(P[Ii], I[Jj])) and
         (BindingsCompatible(P[Ii].Bindings, I[Jj].Bindings, Source)) then
      begin
        M := P[Ii];
        M.Bindings := MergeBindings(P[Ii].Bindings, I[Jj].Bindings);
        M.Deeper := P[Ii].Deeper or I[Jj].Deeper;
        SetLength(Result, Length(Result) + 1);
        Result[Length(Result) - 1] := M;
      end;
    end;
end;

function RemoveInside(const P, N: TPatMatchArray; const Source: string): TPatMatchArray;
var
  I, J: Integer;
  Keep: Boolean;
begin
  Result := nil;
  for I := 0 to High(P) do
  begin
    Keep := True;
    for J := 0 to High(N) do
    begin
      if (RangeInside(P[I], N[J])) and
         (BindingsCompatible(P[I].Bindings, N[J].Bindings, Source)) then
      begin
        Keep := False;
        Break;
      end;
    end;
    if Keep then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[Length(Result) - 1] := P[I];
    end;
  end;
end;

function RemoveEqual(const P, N: TPatMatchArray; const Source: string): TPatMatchArray;
var
  I, J: Integer;
  Keep: Boolean;
begin
  Result := nil;
  for I := 0 to High(P) do
  begin
    Keep := True;
    for J := 0 to High(N) do
    begin
      if (P[I].StartByte = N[J].StartByte) and
         (P[I].EndByte = N[J].EndByte) and
         (BindingsCompatible(P[I].Bindings, N[J].Bindings, Source)) then
      begin
        Keep := False;
        Break;
      end;
    end;
    if Keep then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[Length(Result) - 1] := P[I];
    end;
  end;
end;

procedure SortMatches(var A: TPatMatchArray);
var
  I, J: Integer;
  Tmp: TPatMatch;
begin
  // 安定な挿入ソート：件数が数千程度なので O(n^2) で十分
  for I := 1 to High(A) do
  begin
    Tmp := A[I];
    J := I - 1;
    while (J >= 0) and
          ((A[J].StartByte > Tmp.StartByte) or
           ((A[J].StartByte = Tmp.StartByte) and (A[J].EndByte > Tmp.EndByte))) do
    begin
      A[J + 1] := A[J];
      Dec(J);
    end;
    A[J + 1] := Tmp;
  end;
end;

function BindingsIdentical(const A, B: TBindingArray): Boolean;
var
  I, J: Integer;
begin
  Result := False;
  if Length(A) <> Length(B) then
    Exit;
  for I := 0 to High(A) do
  begin
    Result := False;
    for J := 0 to High(B) do
    begin
      if (A[I].Name = B[J].Name) and
         (A[I].IsRange = B[J].IsRange) and
         (A[I].StartByte = B[J].StartByte) and
         (A[I].EndByte = B[J].EndByte) then
      begin
        Result := True;
        Break;
      end;
    end;
    if not Result then
      Exit;
  end;
  Result := True;
end;

function DedupMatches(const A: TPatMatchArray): TPatMatchArray;
var
  I, J, K: Integer;
  GroupEnd: Integer;
  Kept: TPatMatchArray;
  IsDup: Boolean;
begin
  Result := nil;
  I := 0;
  while I < Length(A) do
  begin
    Kept := nil;
    GroupEnd := I;
    while (GroupEnd < Length(A)) and
          (A[GroupEnd].StartByte = A[I].StartByte) and
          (A[GroupEnd].EndByte = A[I].EndByte) do
      Inc(GroupEnd);
    for J := I to GroupEnd - 1 do
    begin
      IsDup := False;
      for K := 0 to High(Kept) do
      begin
        if BindingsIdentical(A[J].Bindings, Kept[K].Bindings) then
        begin
          Kept[K].Deeper := Kept[K].Deeper and A[J].Deeper;
          IsDup := True;
          Break;
        end;
      end;
      if not IsDup then
      begin
        SetLength(Kept, Length(Kept) + 1);
        Kept[Length(Kept) - 1] := A[J];
      end;
    end;
    for J := 0 to High(Kept) do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[Length(Result) - 1] := Kept[J];
    end;
    I := GroupEnd;
  end;
end;

function EvaluateFormula(F: TFormula; const Root: TSNode; const Source: string;
  GoDeeperStmt: Boolean): TPatMatchArray;

  // Cur / S は再帰ごとに持つこと。patterns の中の pattern-either の中に patterns が
  // あると、内側の評価が外側の途中経過を上書きしてしまうため。
  function Eval(Node: TFormula): TPatMatchArray;
  var
    I, J: Integer;
    Part, Cur, S: TPatMatchArray;
    HasCur: Boolean;
  begin
    Result := nil;
    case Node.Kind of
      fkPattern:
        Result := FindMatches(Node.Pattern.Root, Root, Source, GoDeeperStmt);
      fkEither:
        begin
          for I := 0 to High(Node.FChildren) do
          begin
            Part := Eval(Node.FChildren[I]);
            for J := 0 to High(Part) do
            begin
              SetLength(Result, Length(Result) + 1);
              Result[Length(Result) - 1] := Part[J];
            end;
          end;
        end;
      fkPatterns:
        begin
          Cur := nil;
          // 最初の正の項を空の集合と区別するための印。Cur = nil で判定すると、最初の項が
          // 1 件も一致しないときに 2 番目の項の結果がそのまま残ってしまう。
          HasCur := False;
          for I := 0 to High(Node.FChildren) do
          begin
            if IsPositiveKind(Node.FChildren[I].Kind) then
            begin
              S := Eval(Node.FChildren[I]);
              if not HasCur then
                Cur := S
              else
                Cur := Intersect(Cur, S, Source);
              HasCur := True;
            end;
          end;
          if Length(Cur) = 0 then
            Exit;
          for I := 0 to High(Node.FChildren) do
          begin
            if Node.FChildren[I].Kind = fkInside then
            begin
              S := FindMatches(Node.FChildren[I].Pattern.Root, Root, Source, GoDeeperStmt);
              Cur := KeepInside(Cur, S, Source);
            end;
          end;
          for I := 0 to High(Node.FChildren) do
          begin
            if Node.FChildren[I].Kind = fkNotInside then
            begin
              S := FindMatches(Node.FChildren[I].Pattern.Root, Root, Source, GoDeeperStmt);
              Cur := RemoveInside(Cur, S, Source);
            end;
          end;
          for I := 0 to High(Node.FChildren) do
          begin
            if Node.FChildren[I].Kind = fkNot then
            begin
              S := FindMatches(Node.FChildren[I].Pattern.Root, Root, Source, GoDeeperStmt);
              Cur := RemoveEqual(Cur, S, Source);
            end;
          end;
          Result := Cur;
        end;
    end;
  end;

begin
  Result := Eval(F);
  SortMatches(Result);
  Result := DedupMatches(Result);
end;

function DumpFormula(F: TFormula; Indent: Integer): string;
var
  I: Integer;
  PatDump, Line: string;
  NLIdx: Integer;
begin
  Result := StringOfChar(' ', Indent) + FormulaKeyName(F.Kind) + ':' + #10;
  if (F.Kind = fkPattern) or (F.Kind = fkNot) or
     (F.Kind = fkInside) or (F.Kind = fkNotInside) then
  begin
    PatDump := DumpPattern(F.Pattern);
    I := 1;
    while I <= Length(PatDump) do
    begin
      NLIdx := Pos(#10, Copy(PatDump, I, Length(PatDump) - I + 1));
      if NLIdx = 0 then
      begin
        Line := Copy(PatDump, I, Length(PatDump) - I + 1);
        if Line <> '' then
          Result := Result + StringOfChar(' ', Indent + 2) + Line + #10;
        Break;
      end;
      Line := Copy(PatDump, I, NLIdx - 1);
      if Line <> '' then
        Result := Result + StringOfChar(' ', Indent + 2) + Line + #10;
      I := I + NLIdx;
    end;
  end
  else
  begin
    for I := 0 to High(F.FChildren) do
      Result := Result + DumpFormula(F.FChildren[I], Indent + 2);
  end;
end;

procedure CollectBoundNames(F: TFormula; var MetaVars, MetaVarEllipses: TStringArray);
var
  I, J: Integer;
  Name: string;
  Found: Boolean;
begin
  case F.Kind of
    fkPattern, fkInside:
      begin
        for I := 0 to High(F.Pattern.MetaVars) do
        begin
          Name := F.Pattern.MetaVars[I];
          Found := False;
          for J := 0 to High(MetaVars) do
          begin
            if MetaVars[J] = Name then
            begin
              Found := True;
              Break;
            end;
          end;
          if not Found then
          begin
            SetLength(MetaVars, Length(MetaVars) + 1);
            MetaVars[Length(MetaVars) - 1] := Name;
          end;
        end;
        for I := 0 to High(F.Pattern.MetaVarEllipses) do
        begin
          Name := F.Pattern.MetaVarEllipses[I];
          Found := False;
          for J := 0 to High(MetaVarEllipses) do
          begin
            if MetaVarEllipses[J] = Name then
            begin
              Found := True;
              Break;
            end;
          end;
          if not Found then
          begin
            SetLength(MetaVarEllipses, Length(MetaVarEllipses) + 1);
            MetaVarEllipses[Length(MetaVarEllipses) - 1] := Name;
          end;
        end;
      end;
    fkPatterns, fkEither:
      for I := 0 to High(F.FChildren) do
        CollectBoundNames(F.FChildren[I], MetaVars, MetaVarEllipses);
    fkNot, fkNotInside:
      ;
  end;
end;

end.
