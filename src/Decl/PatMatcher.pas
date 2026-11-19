unit PatMatcher;

{$mode objfpc}{$H+}

// パターン IR（PatCompiler）を対象ファイルの tree-sitter の木と照合する（設計書 4.3 節）。
// M1 の範囲: 名前付きの子の比較、extras（comment / pp）の除外、葉の比較規則、
// メタ変数の単一化、子の列の ellipsis（バックトラック）、括弧の透過。
// 括弧なしの呼び出しと `raise;`（設計書 4.3 の Pascal 固有の扱い）。文の並び（pkSequence）は M2。

interface

uses
  SysUtils, TSBindings, PatCompiler;

type
  TMetaVarBinding = record
    Name: string;
    // $X: 束縛したノード（括弧は剥がした後のもの）。
    Node: TSNode;
    // $...X のとき True。範囲は束縛した兄弟の列の [StartByte, EndByte)。
    // 0 個に一致したときは StartByte = EndByte。
    IsRange: Boolean;
    StartByte, EndByte: LongWord;
  end;
  TBindingArray = array of TMetaVarBinding;

  TPatMatch = record
    StartByte, EndByte: LongWord;
    StartPoint, EndPoint: TSPoint;
    Bindings: TBindingArray;
  end;
  TPatMatchArray = array of TPatMatch;

// Root 以下の全ノードについて Pattern との一致を調べ、一致したものをソース順に返す。
// Source は Root を得たときにパースしたテキスト（葉のテキスト比較に使う）。
// Pattern.Kind = pkSequence は M2 まで未対応で、空の結果を返す。
function FindMatches(Pattern: TPatNode; const Root: TSNode; const Source: string): TPatMatchArray;

// 束縛の値をソーステキストとして取り出す（メッセージの $X 補間とデバッグ出力用）。
function BindingText(const B: TMetaVarBinding; const Source: string): string;

// 2 つの束縛が同じものを指すか（合成の「束縛が両立する」の判定。設計書 4.4）。
// 単一ノード同士は同じメタ変数の 2 回目の出現と同じ構造比較で、範囲の束縛が絡むときは
// ソーステキストの完全一致で比べる（照合器の `$...X` の 2 回目以降と同じ。M3 で見直す）。
function BindingsEquivalent(const A, B: TMetaVarBinding; const Source: string): Boolean;

implementation

type
  TChildRec = record
    Node: TSNode;
    Field: string;
  end;
  TChildList = array of TChildRec;

function MatchNode(P: TPatNode; T: TSNode; const Source: string; var B: TBindingArray): Boolean; forward;
function MatchList(P: TPatNode; PI: Integer; const TL: TChildList; TI: Integer; ParentNode: TSNode; const Source: string; var B: TBindingArray): Boolean; forward;

function StripParens(T: TSNode): TSNode;
var
  Count: Integer;
  I: Integer;
  Found: TSNode;
  FoundCount: Integer;
  HasFound: Boolean;
begin
  Result := T;
  while (string(ts_node_type(Result)) = 'exprParens') do
  begin
    Count := Integer(ts_node_child_count(Result));
    FoundCount := 0;
    HasFound := False;
    for I := 0 to Count - 1 do
    begin
      if (ts_node_is_named(ts_node_child(Result, LongWord(I)))) and (not ts_node_is_extra(ts_node_child(Result, LongWord(I)))) then
      begin
        Inc(FoundCount);
        Found := ts_node_child(Result, LongWord(I));
        HasFound := True;
      end;
    end;
    if (FoundCount <> 1) or (not HasFound) then
      Break;
    Result := Found;
  end;
end;

function IsKeywordNode(T: TSNode): Boolean;
var
  TName: string;
begin
  TName := string(ts_node_type(T));
  Result := (Length(TName) >= 2) and (TName[1] = 'k') and (TName[2] in ['A'..'Z']);
end;

function LeafTextEqual(NodeType, A, B: string): Boolean;
begin
  if NodeType = 'identifier' then
  begin
    // Pascal identifiers are case-insensitive; & escapes a reserved word
    if (Length(A) > 0) and (A[1] = '&') then
      Delete(A, 1, 1);
    if (Length(B) > 0) and (B[1] = '&') then
      Delete(B, 1, 1);
    Result := SameText(A, B);
  end
  else if NodeType = 'literalString' then
    Result := (A = B)
  else
    Result := SameText(A, B);
end;

function BuildChildList(T: TSNode): TChildList;
var
  Count: Integer;
  I: Integer;
  P: PAnsiChar;
  TempCount: Integer;
begin
  Result := nil;
  Count := Integer(ts_node_child_count(T));
  TempCount := 0;
  for I := 0 to Count - 1 do
  begin
    if (ts_node_is_named(ts_node_child(T, LongWord(I))) and (not ts_node_is_extra(ts_node_child(T, LongWord(I)))))
      or IsBareRaiseError(ts_node_child(T, LongWord(I))) then
      Inc(TempCount);
  end;
  SetLength(Result, TempCount);
  TempCount := 0;
  for I := 0 to Count - 1 do
  begin
    if (ts_node_is_named(ts_node_child(T, LongWord(I))) and (not ts_node_is_extra(ts_node_child(T, LongWord(I)))))
      or IsBareRaiseError(ts_node_child(T, LongWord(I))) then
    begin
      Result[TempCount].Node := ts_node_child(T, LongWord(I));
      // bare raise の ERROR にはフィールド名が付かない（実測）
      if IsBareRaiseError(ts_node_child(T, LongWord(I))) then
        Result[TempCount].Field := ''
      else
      begin
        P := ts_node_field_name_for_child(T, LongWord(I));
        if P <> nil then
          Result[TempCount].Field := string(P)
        else
          Result[TempCount].Field := '';
      end;
      Inc(TempCount);
    end;
  end;
end;

function FindBinding(const B: TBindingArray; const Name: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to Length(B) - 1 do
  begin
    if B[I].Name = Name then
    begin
      Result := I;
      Exit;
    end;
  end;
end;

function NodesEquivalent(A, Bn: TSNode; const Source: string): Boolean;
var
  AType: string;
  AList, BList: TChildList;
  I: Integer;
  AText, BText: string;
begin
  A := StripParens(A);
  Bn := StripParens(Bn);

  if ts_node_symbol(A) <> ts_node_symbol(Bn) then
  begin
    Result := False;
    Exit;
  end;

  AList := BuildChildList(A);
  BList := BuildChildList(Bn);

  if Length(AList) <> Length(BList) then
  begin
    Result := False;
    Exit;
  end;

  if Length(AList) = 0 then
  begin
    AType := string(ts_node_type(A));
    AText := Copy(Source, ts_node_start_byte(A) + 1, ts_node_end_byte(A) - ts_node_start_byte(A));
    BText := Copy(Source, ts_node_start_byte(Bn) + 1, ts_node_end_byte(Bn) - ts_node_start_byte(Bn));
    Result := LeafTextEqual(AType, AText, BText);
    Exit;
  end;

  Result := True;
  for I := 0 to Length(AList) - 1 do
  begin
    if AList[I].Field <> BList[I].Field then
    begin
      Result := False;
      Exit;
    end;
    if not NodesEquivalent(AList[I].Node, BList[I].Node, Source) then
    begin
      Result := False;
      Exit;
    end;
  end;
end;

function MatchNode(P: TPatNode; T: TSNode; const Source: string; var B: TBindingArray): Boolean;
var
  TText: string;
  TL: TChildList;
  BindIdx: Integer;
begin
  T := StripParens(T);

  // bare raise の ERROR 以外のエラー・MISSING には一致させない（設計書 4.3）
  if HasErrorOtherThanBareRaise(T) then
  begin
    Result := False;
    Exit;
  end;

  case P.Kind of
    pkMetaVar:
    begin
      // メタ変数は extras（bare raise の ERROR 等）に一致しない
      if IsBareRaiseError(T) then
      begin
        Result := False;
        Exit;
      end;
      // A metavariable stands for an expression/name, never for a keyword
      if IsKeywordNode(T) then
      begin
        Result := False;
        Exit;
      end;
      if P.MetaVarName = '_' then
      begin
        Result := True;
        Exit;
      end;
      BindIdx := FindBinding(B, P.MetaVarName);
      if BindIdx >= 0 then
      begin
        if B[BindIdx].IsRange then
        begin
          Result := False;
          Exit;
        end;
        Result := NodesEquivalent(B[BindIdx].Node, T, Source);
        Exit;
      end;
      SetLength(B, Length(B) + 1);
      B[Length(B) - 1].Name := P.MetaVarName;
      B[Length(B) - 1].Node := T;
      B[Length(B) - 1].IsRange := False;
      B[Length(B) - 1].StartByte := ts_node_start_byte(T);
      B[Length(B) - 1].EndByte := ts_node_end_byte(T);
      Result := True;
      Exit;
    end;

    pkBareRaise:
      begin
        Result := IsBareRaiseError(T);
        Exit;
      end;

    pkEllipsis, pkMetaVarEllipsis, pkSequence:
      begin
        Result := False;
        Exit;
      end;

    pkNode:
    begin
      if ts_node_symbol(T) <> P.Symbol then
      begin
        Result := False;
        Exit;
      end;
      if P.ChildCount = 0 then
      begin
        if (P.NodeType = 'literalString') and (P.Text = '''...''') then
        begin
          // The pattern '...' matches any string literal
          Result := True;
          Exit;
        end;
        TText := Copy(Source, ts_node_start_byte(T) + 1, ts_node_end_byte(T) - ts_node_start_byte(T));
        Result := LeafTextEqual(P.NodeType, P.Text, TText);
        Exit;
      end;
      TL := BuildChildList(T);
      Result := MatchList(P, 0, TL, 0, T, Source, B);
      Exit;
    end;
  end;
end;

function CanMatchAbsent(C: TPatNode): Boolean;
var
  I: Integer;
begin
  Result := (C.Kind = pkNode) and (C.ChildCount > 0);
  if not Result then
    Exit;
  for I := 0 to C.ChildCount - 1 do
    if not (C.Children[I].Kind in [pkEllipsis, pkMetaVarEllipsis]) then
    begin
      Result := False;
      Exit;
    end;
end;

// CanMatchAbsent なノードを「対象側に無い」として一致させるとき、その中の $...X を
// 空の範囲に束縛する（既に束縛済みなら、それも空であることを求める）。
function BindEmptyEllipses(C: TPatNode; At: LongWord; AtNode: TSNode; const Source: string;
  var B: TBindingArray): Boolean;
var
  I, BindIdx: Integer;
begin
  Result := True;
  for I := 0 to C.ChildCount - 1 do
  begin
    if C.Children[I].Kind <> pkMetaVarEllipsis then
      Continue;
    BindIdx := FindBinding(B, C.Children[I].MetaVarName);
    if BindIdx >= 0 then
    begin
      if (not B[BindIdx].IsRange) or (BindingText(B[BindIdx], Source) <> '') then
      begin
        Result := False;
        Exit;
      end;
    end
    else
    begin
      SetLength(B, Length(B) + 1);
      B[High(B)].Name := C.Children[I].MetaVarName;
      B[High(B)].Node := AtNode;
      B[High(B)].IsRange := True;
      B[High(B)].StartByte := At;
      B[High(B)].EndByte := At;
    end;
  end;
end;

function MatchParenlessCall(P: TPatNode; T: TSNode; const Source: string; var B: TBindingArray): Boolean;
var
  Entity: TPatNode;
  Args: TPatNode;
  HasEntity, HasArgs: Boolean;
  I: Integer;
  Saved: TBindingArray;
begin
  Result := False;
  Entity := nil;
  Args := nil;
  if (P.Kind <> pkNode) or (P.NodeType <> 'exprCall') then
    Exit;
  if (string(ts_node_type(T)) <> 'identifier') and (string(ts_node_type(T)) <> 'exprDot') then
    Exit;

  // パターン子は entity 1 個 + 任意で args 1 個のみ（それ以外の子があると括弧なし呼び出しではない）
  HasEntity := False;
  HasArgs := False;
  for I := 0 to P.ChildCount - 1 do
  begin
    if P.Children[I].FieldName = 'entity' then
    begin
      if HasEntity then Exit;
      HasEntity := True;
      Entity := P.Children[I];
    end
    else if P.Children[I].FieldName = 'args' then
    begin
      if HasArgs then Exit;
      HasArgs := True;
      Args := P.Children[I];
    end
    else
      Exit;
  end;
  if not HasEntity then
    Exit;

  Saved := Copy(B);

  // 括弧なしの呼び出しには引数が無い。`Foo($X)` のように引数を要求するパターンは一致させず、
  // `Foo(...)` のように引数が ellipsis だけのときに限る（0 個の引数として扱う）。
  if HasArgs then
  begin
    if not CanMatchAbsent(Args) then
      Exit;
    if not BindEmptyEllipses(Args, ts_node_end_byte(T), T, Source, B) then
    begin
      B := Saved;
      Exit;
    end;
  end;

  if MatchNode(Entity, T, Source, B) then
    Result := True
  else
    B := Saved;
end;

function MatchList(P: TPatNode; PI: Integer; const TL: TChildList; TI: Integer; ParentNode: TSNode; const Source: string; var B: TBindingArray): Boolean;
var
  C: TPatNode;
  K: Integer;
  Saved: TBindingArray;
  BindIdx: Integer;
  NewStart, NewEnd, EmptyAt: LongWord;
  ExistingText, NewText: string;
begin
  if PI = P.ChildCount then
  begin
    Result := (TI = Length(TL));
    Exit;
  end;

  C := P.Children[PI];

  if (C.Kind = pkEllipsis) or (C.Kind = pkMetaVarEllipsis) then
  begin
    for K := 0 to Length(TL) - TI do
    begin
      // Copy makes a real snapshot; plain assignment would share the array
      Saved := Copy(B);

      if C.Kind = pkMetaVarEllipsis then
      begin
        if K > 0 then
        begin
          NewStart := ts_node_start_byte(TL[TI].Node);
          NewEnd := ts_node_end_byte(TL[TI + K - 1].Node);
        end
        else
        begin
          if TI < Length(TL) then
          begin
            NewStart := ts_node_start_byte(TL[TI].Node);
            NewEnd := NewStart;
          end
          else
          begin
            NewStart := ts_node_end_byte(ParentNode);
            NewEnd := NewStart;
          end;
        end;

        BindIdx := FindBinding(B, C.MetaVarName);
        if BindIdx >= 0 then
        begin
          if not B[BindIdx].IsRange then
          begin
            B := Saved;
            Continue;
          end;
          ExistingText := Copy(Source, B[BindIdx].StartByte + 1, B[BindIdx].EndByte - B[BindIdx].StartByte);
          NewText := Copy(Source, NewStart + 1, NewEnd - NewStart);
          if ExistingText <> NewText then
          begin
            B := Saved;
            Continue;
          end;
        end
        else
        begin
          SetLength(B, Length(B) + 1);
          B[Length(B) - 1].Name := C.MetaVarName;
          if K > 0 then
            B[Length(B) - 1].Node := TL[TI].Node
          else
          begin
            if TI < Length(TL) then
              B[Length(B) - 1].Node := TL[TI].Node
            else
              B[Length(B) - 1].Node := ParentNode;
          end;
          B[Length(B) - 1].IsRange := True;
          B[Length(B) - 1].StartByte := NewStart;
          B[Length(B) - 1].EndByte := NewEnd;
        end;
      end;

      if MatchList(P, PI + 1, TL, TI + K, ParentNode, Source, B) then
      begin
        Result := True;
        Exit;
      end;
      B := Saved;
    end;
    Result := False;
    Exit;
  end;

  // 空の引数リストの `Foo()` には exprArgs ノード自体が無い（tree-sitter-pascal の木の形）。
  // opengrep と同じく `Foo(...)` を `Foo()` にも一致させるため、子が ellipsis だけの
  // パターンノードは、対象側に対応する子が無いときにも「0 個の列」として一致させる。
  if (TI >= Length(TL)) or (C.FieldName <> TL[TI].Field) then
  begin
    Result := False;
    if CanMatchAbsent(C) then
    begin
      Saved := Copy(B);
      if TI < Length(TL) then
        EmptyAt := ts_node_start_byte(TL[TI].Node)
      else
        EmptyAt := ts_node_end_byte(ParentNode);
      if BindEmptyEllipses(C, EmptyAt, ParentNode, Source, B)
        and MatchList(P, PI + 1, TL, TI, ParentNode, Source, B) then
        Result := True
      else
        B := Saved;
    end;
    Exit;
  end;

  Saved := Copy(B);
  if (MatchNode(C, TL[TI].Node, Source, B)) and (MatchList(P, PI + 1, TL, TI + 1, ParentNode, Source, B)) then
  begin
    Result := True;
    Exit;
  end;
  B := Saved;
  Result := False;
  // 括弧なしの呼び出しは文の位置でだけ認める。式の位置の `Y := Foo` は変数の参照と区別できない。
  if string(ts_node_type(ParentNode)) = 'statement' then
  begin
    if (MatchParenlessCall(C, TL[TI].Node, Source, B)) and (MatchList(P, PI + 1, TL, TI + 1, ParentNode, Source, B)) then
      Result := True
    else
      B := Saved;
  end;
end;

procedure VisitForMatch(Pattern: TPatNode; Node: TSNode; const Source: string; ParentIsStatement: Boolean; var Matches: TPatMatchArray);
var
  NType: string;
  B: TBindingArray;
  M: TPatMatch;
  Cnt: Integer;
  J: Integer;
  Child: TSNode;
begin
  NType := string(ts_node_type(Node));
  // Its inner node is visited too, so trying both would report the same match twice
  if NType <> 'exprParens' then
  begin
    B := nil;
    if MatchNode(Pattern, Node, Source, B) then
    begin
      SetLength(Matches, Length(Matches) + 1);
      M.StartByte := ts_node_start_byte(Node);
      M.EndByte := ts_node_end_byte(Node);
      M.StartPoint := ts_node_start_point(Node);
      M.EndPoint := ts_node_end_point(Node);
      M.Bindings := B;
      Matches[Length(Matches) - 1] := M;
    end
    else if ParentIsStatement then
    begin
      // 文の位置でのみ括弧なし呼び出しに一致させる（式位置では変数参照と区別できない）
      B := nil;
      if MatchParenlessCall(Pattern, Node, Source, B) then
      begin
        SetLength(Matches, Length(Matches) + 1);
        M.StartByte := ts_node_start_byte(Node);
        M.EndByte := ts_node_end_byte(Node);
        M.StartPoint := ts_node_start_point(Node);
        M.EndPoint := ts_node_end_point(Node);
        M.Bindings := B;
        Matches[Length(Matches) - 1] := M;
      end;
    end;
  end;

  Cnt := Integer(ts_node_child_count(Node));
  for J := 0 to Cnt - 1 do
  begin
    Child := ts_node_child(Node, LongWord(J));
    // bare raise の ERROR は extra だが照合対象にする（パターンが raise; 単独の場合）
    if ((ts_node_is_named(Child)) and (not ts_node_is_extra(Child))) or IsBareRaiseError(Child) then
      VisitForMatch(Pattern, Child, Source, (string(ts_node_type(Node)) = 'statement'), Matches);
  end;
end;

function FindMatches(Pattern: TPatNode; const Root: TSNode; const Source: string): TPatMatchArray;
begin
  Result := nil;
  if Pattern.Kind = pkSequence then
    Exit;
  // ルートの親は statement ではない（ファイル全体を走査している）
  VisitForMatch(Pattern, Root, Source, False, Result);
end;

function BindingText(const B: TMetaVarBinding; const Source: string): string;
begin
  Result := Copy(Source, B.StartByte + 1, B.EndByte - B.StartByte);
end;

function BindingsEquivalent(const A, B: TMetaVarBinding; const Source: string): Boolean;
begin
  if (not A.IsRange) and (not B.IsRange) then
    Result := NodesEquivalent(A.Node, B.Node, Source)
  else
    Result := BindingText(A, Source) = BindingText(B, Source);
end;

end.
