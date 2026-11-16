unit PatCompiler;

{$mode objfpc}{$H+}

// パターン文字列を tree-sitter-pascal でパースし、自前のパターン IR に変換する
// （設計書 4.2 節 (1)(5)）。木をそのまま保持せず IR にするのは、プレースホルダを
// メタ変数・ellipsis に戻す処理とラッパーの除去を読み込み時に一度で済ませ、
// TSTree の寿命をルールの寿命から切り離すため（変換後すぐ ts_tree_delete する）。

interface

uses
  SysUtils, TSBindings, PatLexer;

type
  TPatKind = (
    pkNode,             // 対象側の同じ種別の名前付きノードと照合する。子が無ければ葉（Text で比較）
    pkMetaVar,          // $X（$_ も含む。束縛しないかどうかはマッチャが名前で判断する）
    pkEllipsis,         // ...
    pkMetaVarEllipsis,  // $...X
    pkSequence          // 文や宣言が 2 個以上並んだパターン。子がその並び
  );

  // どのラッパーでパースできたか（設計書 4.2 (1) の 1〜3）。
  TPatWrapper = (pwAsIs, pwStatement, pwExpression);

  TPatNode = class
  private
    FKind: TPatKind;
    FNodeType: string;
    FSymbol: Word;
    FFieldName: string;
    FText: string;
    FMetaVarName: string;
    FChildren: array of TPatNode;
    function GetChildCount: Integer;
    function GetChild(Index: Integer): TPatNode;
  public
    constructor Create(AKind: TPatKind);
    // 子ノードも解放する（子の所有者は親）。
    destructor Destroy; override;
    procedure AddChild(Child: TPatNode);
    property Kind: TPatKind read FKind;
    // pkNode のみ: tree-sitter のノード種別名と記号番号。
    property NodeType: string read FNodeType write FNodeType;
    property Symbol: Word read FSymbol write FSymbol;
    // 親から見たフィールド名（無ければ ''）。全種別で有効。
    property FieldName: string read FFieldName write FFieldName;
    // pkNode の葉のみ: パターン上のソーステキスト。
    property Text: string read FText write FText;
    // pkMetaVar / pkMetaVarEllipsis のみ: `$` や `$...` を除いた名前。
    property MetaVarName: string read FMetaVarName write FMetaVarName;
    property ChildCount: Integer read GetChildCount;
    property Children[Index: Integer]: TPatNode read GetChild;
  end;

  TPatCompileResult = record
    Ok: Boolean;
    // Ok のとき呼び出し側が所有する（Free する）。Ok でなければ nil。
    Root: TPatNode;
    Wrapper: TPatWrapper;
    ErrorMessage: string;
    // PatLexer から引き継いだ警告（pascal_hex_dollar）。
    Warnings: TStringArray;
    MetaVars: TStringArray;
    MetaVarEllipses: TStringArray;
  end;

function CompilePattern(const Src: string; const Opts: TPatLexOptions): TPatCompileResult;

// ゴールデンテスト用のテキスト表現（設計書 7.1）。tree-sitter-pascal を更新したときに
// パターンの木の形が変わったことを差分で検出するために使う（CLAUDE.md ルール2）。
function DumpPattern(const R: TPatCompileResult): string;

implementation

type
  TNodeList = array of TSNode;

{ TPatNode }

constructor TPatNode.Create(AKind: TPatKind);
begin
  inherited Create;
  FKind := AKind;
end;

destructor TPatNode.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FChildren) do
    FChildren[I].Free;
  inherited Destroy;
end;

procedure TPatNode.AddChild(Child: TPatNode);
begin
  SetLength(FChildren, Length(FChildren) + 1);
  FChildren[Length(FChildren) - 1] := Child;
end;

function TPatNode.GetChildCount: Integer;
begin
  Result := Length(FChildren);
end;

function TPatNode.GetChild(Index: Integer): TPatNode;
begin
  Result := FChildren[Index];
end;

function IsRelevant(N: TSNode): Boolean;
begin
  Result := (ts_node_is_named(N) and (not ts_node_is_extra(N)));
end;

function CountRelevant(N: TSNode): Integer;
var
  Cnt: Integer;
  I: Integer;
  C: TSNode;
begin
  Result := 0;
  Cnt := ts_node_child_count(N);
  for I := 0 to Cnt - 1 do
  begin
    C := ts_node_child(N, LongWord(I));
    if IsRelevant(C) then
      Inc(Result);
  end;
end;

function GetRelevantChild(N: TSNode; RelIdx: Integer): TSNode;
var
  Cnt: Integer;
  I: Integer;
  C: TSNode;
  Seen: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Cnt := ts_node_child_count(N);
  Seen := 0;
  for I := 0 to Cnt - 1 do
  begin
    C := ts_node_child(N, LongWord(I));
    if IsRelevant(C) then
    begin
      if Seen = RelIdx then
      begin
        Result := C;
        Exit;
      end;
      Inc(Seen);
    end;
  end;
end;

function NodeText(N: TSNode; const Code: string): string;
begin
  Result := Copy(Code, ts_node_start_byte(N) + 1, ts_node_end_byte(N) - ts_node_start_byte(N));
end;

function NodeTypeName(N: TSNode): string;
begin
  Result := PAnsiChar(ts_node_type(N));
end;

function CompilePattern(const Src: string; const Opts: TPatLexOptions): TPatCompileResult;
var
  L: TPatLexResult;
  P: TSParser;
  Code: string;
  Root: TPatNode;
  Wr: TPatWrapper;

  function Convert(N: TSNode; Field: string): TPatNode;
  var
    Txt: string;
    Cnt2: Integer;
    I2: Integer;
    C2: TSNode;
    FN2: PAnsiChar;
    RelCnt2: Integer;
    CTxt: string;
  begin
    Txt := NodeText(N, Code);

    if NodeTypeName(N) = 'identifier' then
    begin
      if Txt = EllipsisPlaceholder then
      begin
        Result := TPatNode.Create(pkEllipsis);
      end
      else if (Pos(MetaVarEllipsisPrefix, Txt) = 1) and (Copy(Txt, Length(Txt) - Length(PlaceholderSuffix) + 1, Length(PlaceholderSuffix)) = PlaceholderSuffix) then
      begin
        Result := TPatNode.Create(pkMetaVarEllipsis);
        Result.MetaVarName := Copy(Txt, Length(MetaVarEllipsisPrefix) + 1, Length(Txt) - Length(MetaVarEllipsisPrefix) - Length(PlaceholderSuffix));
      end
      else if (Pos(MetaVarPrefix, Txt) = 1) and (Copy(Txt, Length(Txt) - Length(PlaceholderSuffix) + 1, Length(PlaceholderSuffix)) = PlaceholderSuffix) then
      begin
        Result := TPatNode.Create(pkMetaVar);
        Result.MetaVarName := Copy(Txt, Length(MetaVarPrefix) + 1, Length(Txt) - Length(MetaVarPrefix) - Length(PlaceholderSuffix));
      end
      else
      begin
        Result := TPatNode.Create(pkNode);
        Result.NodeType := 'identifier';
        Result.Symbol := ts_node_symbol(N);
        Result.Text := Txt;
      end;
      Result.FieldName := Field;
      Exit;
    end;

    if NodeTypeName(N) = 'statement' then
    begin
      RelCnt2 := CountRelevant(N);
      if RelCnt2 = 1 then
      begin
        C2 := GetRelevantChild(N, 0);
        if NodeTypeName(C2) = 'identifier' then
        begin
          CTxt := NodeText(C2, Code);
          if (CTxt = EllipsisPlaceholder) or (Pos(MetaVarEllipsisPrefix, CTxt) = 1) then
          begin
            Result := Convert(C2, Field);
            Exit;
          end;
        end;
      end;
    end;

    // 括弧はマッチング時に透明（設計書 4.3）：パターン側で除去し、
    // マッチャは対象側で括弧をスキップするだけで済む
    if NodeTypeName(N) = 'exprParens' then
    begin
      RelCnt2 := CountRelevant(N);
      if RelCnt2 = 1 then
      begin
        C2 := GetRelevantChild(N, 0);
        Result := Convert(C2, Field);
        Exit;
      end;
    end;

    Result := TPatNode.Create(pkNode);
    Result.NodeType := NodeTypeName(N);
    Result.Symbol := ts_node_symbol(N);
    Result.FieldName := Field;

    RelCnt2 := CountRelevant(N);
    if RelCnt2 = 0 then
    begin
      Result.Text := Txt;
    end
    else
    begin
      Cnt2 := ts_node_child_count(N);
      for I2 := 0 to Cnt2 - 1 do
      begin
        C2 := ts_node_child(N, LongWord(I2));
        if IsRelevant(C2) then
        begin
          FN2 := ts_node_field_name_for_child(N, LongWord(I2));
          if FN2 <> nil then
            Result.AddChild(Convert(C2, string(FN2)))
          else
            Result.AddChild(Convert(C2, ''));
        end;
      end;
    end;
  end;

  function CollectBlockItems(const RootNode: TSNode; out Items: TNodeList): Boolean;
  var
    RelCnt: Integer;
    BlockTr: TSNode;
    Cnt: Integer;
    I: Integer;
    C: TSNode;
  begin
    Result := False;
    RelCnt := CountRelevant(RootNode);
    if RelCnt <> 1 then Exit;
    BlockTr := GetRelevantChild(RootNode, 0);
    if NodeTypeName(BlockTr) <> 'blockTr' then Exit;

    Cnt := ts_node_child_count(BlockTr);
    SetLength(Items, 0);
    for I := 0 to Cnt - 1 do
    begin
      C := ts_node_child(BlockTr, LongWord(I));
      if IsRelevant(C) then
      begin
        SetLength(Items, Length(Items) + 1);
        Items[Length(Items) - 1] := C;
      end;
    end;

    if (Length(Items) > 0) and (NodeTypeName(Items[0]) = 'kBegin') then
    begin
      for I := 1 to Length(Items) - 1 do
        Items[I - 1] := Items[I];
      SetLength(Items, Length(Items) - 1);
    end;
    if (Length(Items) > 0) and (NodeTypeName(Items[Length(Items) - 1]) = 'kEnd') then
      SetLength(Items, Length(Items) - 1);

    Result := Length(Items) > 0;
  end;

  function TryWrapper(W: TPatWrapper): Boolean;
  var
    Tree: PTSTree;
    RootNode: TSNode;
    Items: TNodeList;
    Cnt: Integer;
    I: Integer;
    C: TSNode;
    FN: PAnsiChar;
    AssignNode: TSNode;
    FoundRhs: Boolean;
  begin
    Result := False;

    case W of
      pwAsIs: Code := L.Text;
      pwStatement: Code := 'begin ' + L.Text + #10 + ' end';
      pwExpression: Code := 'begin __rawpaco_w__ := ' + L.Text + #10 + ' end';
    end;

    Tree := ts_parser_parse_string(P, nil, PAnsiChar(Code), Length(Code));
    try
      RootNode := ts_tree_root_node(Tree);
      if ts_node_has_error(RootNode) then Exit;

      case W of
        pwAsIs:
          begin
            Cnt := ts_node_child_count(RootNode);
            SetLength(Items, 0);
            for I := 0 to Cnt - 1 do
            begin
              C := ts_node_child(RootNode, LongWord(I));
              if IsRelevant(C) then
              begin
                SetLength(Items, Length(Items) + 1);
                Items[Length(Items) - 1] := C;
              end;
            end;
            if Length(Items) = 0 then Exit;
          end;
        pwStatement:
          begin
            if not CollectBlockItems(RootNode, Items) then Exit;
          end;
        pwExpression:
          begin
            if not CollectBlockItems(RootNode, Items) then Exit;
            if Length(Items) <> 1 then Exit;
            AssignNode := Items[0];
            if NodeTypeName(AssignNode) <> 'assignment' then Exit;
            FoundRhs := False;
            Cnt := ts_node_child_count(AssignNode);
            for I := 0 to Cnt - 1 do
            begin
              C := ts_node_child(AssignNode, LongWord(I));
              FN := ts_node_field_name_for_child(AssignNode, LongWord(I));
              if (FN <> nil) and (string(FN) = 'rhs') then
              begin
                SetLength(Items, 1);
                Items[0] := C;
                FoundRhs := True;
                Break;
              end;
            end;
            if not FoundRhs then Exit;
          end;
      end;

      if Length(Items) = 1 then
      begin
        // 式文は式パターンとして扱う（`Foo($X)` が式内の呼び出しにもマッチする）
        if (NodeTypeName(Items[0]) = 'statement') and (CountRelevant(Items[0]) = 1) then
          Root := Convert(GetRelevantChild(Items[0], 0), '')
        else
          Root := Convert(Items[0], '');
      end
      else
      begin
        Root := TPatNode.Create(pkSequence);
        for I := 0 to Length(Items) - 1 do
          Root.AddChild(Convert(Items[I], ''));
      end;

      Wr := W;
      Result := True;
    finally
      ts_tree_delete(Tree);
    end;
  end;

begin
  Result.Ok := False;
  Result.Root := nil;
  Result.Wrapper := pwAsIs;
  Result.ErrorMessage := '';
  Result.Warnings := nil;
  Result.MetaVars := nil;
  Result.MetaVarEllipses := nil;

  L := PreprocessPattern(Src, Opts);
  if not L.Ok then
  begin
    Result.ErrorMessage := Format('%d:%d: %s', [L.ErrorLine, L.ErrorColumn, L.ErrorMessage]);
    Exit;
  end;
  Result.Warnings := L.Warnings;
  Result.MetaVars := L.MetaVars;
  Result.MetaVarEllipses := L.MetaVarEllipses;

  if Trim(L.Text) = '' then
  begin
    Result.ErrorMessage := 'empty pattern';
    Exit;
  end;

  Root := nil;
  Wr := pwAsIs;

  P := ts_parser_new;
  try
    ts_parser_set_language(P, tree_sitter_pascal);
    if not TryWrapper(pwAsIs) then
      if not TryWrapper(pwStatement) then
        if not TryWrapper(pwExpression) then
        begin
          Result.ErrorMessage := 'the pattern cannot be parsed as Pascal declarations, statements or an expression';
          Exit;
        end;
  finally
    ts_parser_delete(P);
  end;

  // ellipsis のみパターンは拒否（何でもマッチしてしまうため）
  if (Root.Kind = pkEllipsis) or (Root.Kind = pkMetaVarEllipsis) then
  begin
    Root.Free;
    Root := nil;
    Result.ErrorMessage := 'a pattern that is only an ellipsis would match everything';
    Exit;
  end;

  Result.Root := Root;
  Result.Wrapper := Wr;
  Result.Ok := True;
end;

procedure DumpNodeTo(var S: string; N: TPatNode; Depth: Integer);
var
  I: Integer;
  Indent: string;
  Line: string;
begin
  Indent := StringOfChar(' ', Depth * 2);

  if N.FieldName <> '' then
    Line := Indent + N.FieldName + ': '
  else
    Line := Indent;

  case N.Kind of
    pkNode:
      if N.ChildCount = 0 then
        Line := Line + N.NodeType + ' "' + N.Text + '"'
      else
        Line := Line + N.NodeType;
    pkMetaVar:
      Line := Line + '$' + N.MetaVarName;
    pkEllipsis:
      Line := Line + '...';
    pkMetaVarEllipsis:
      Line := Line + '$...' + N.MetaVarName;
    pkSequence:
      Line := Line + 'sequence';
  end;

  S := S + Line + #10;

  for I := 0 to N.ChildCount - 1 do
    DumpNodeTo(S, N.Children[I], Depth + 1);
end;

function DumpPattern(const R: TPatCompileResult): string;
var
  S: string;
  I: Integer;
begin
  if not R.Ok then
  begin
    Result := 'error: ' + R.ErrorMessage + #10;
    Exit;
  end;

  S := '';
  case R.Wrapper of
    pwAsIs: S := S + 'wrapper: as-is' + #10;
    pwStatement: S := S + 'wrapper: statement' + #10;
    pwExpression: S := S + 'wrapper: expression' + #10;
  end;

  for I := 0 to High(R.Warnings) do
    S := S + 'warning: ' + R.Warnings[I] + #10;

  DumpNodeTo(S, R.Root, 0);

  Result := S;
end;

end.
