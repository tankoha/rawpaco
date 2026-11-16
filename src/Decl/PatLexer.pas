unit PatLexer;

{$mode objfpc}{$H+}

// 宣言的ルールのパターン文字列を、tree-sitter-pascal がパースできる Pascal の
// コード片へ字句レベルで書き換える前処理（設計書 4.2 節 (2)(3)）。
// 文法を拡張せずに済ませるための仕組みで（CLAUDE.md ルール2: 文法はピン留めし
// 改変しない）、メタ変数と ellipsis をただの識別子に置き換える。
// 文字列リテラルとコメントの中は置換しない（`'$X'` や `{ ... }` はそのまま）。

interface

uses
  SysUtils;

const
  // プレースホルダ識別子。パターン IR への変換時に、この接頭辞・接尾辞で
  // メタ変数 / ellipsis に戻す。利用者のパターンに `__rawpaco_` で始まる
  // 識別子が書かれていると区別できなくなるため、それは読み込みエラーにする。
  ReservedPrefix = '__rawpaco_';
  MetaVarPrefix = '__rawpaco_mv_';
  MetaVarEllipsisPrefix = '__rawpaco_mvell_';
  PlaceholderSuffix = '__';
  EllipsisPlaceholder = '__rawpaco_ell__';

type
  TPatLexOptions = record
    // ルールの `options: { pascal_hex_dollar: true }`（未決 #3 の決定）。
    // True のとき、16 進数字だけから成る `$ABC` をエラーにせず、Pascal の
    // 字句どおり 16 進リテラルとして残し、警告を 1 件積む。
    PascalHexDollar: Boolean;
  end;

  TPatLexResult = record
    Ok: Boolean;
    // Ok のときの書き換え結果。Ok でなければ空。
    Text: string;
    // Ok でないときの理由と、元のパターン上の位置（1 始まり。列はバイト単位）。
    ErrorMessage: string;
    ErrorLine, ErrorColumn: Integer;
    // PascalHexDollar で 16 進リテラル扱いにした箇所ごとの警告文。
    Warnings: TStringArray;
    // 出現順・重複なしのメタ変数名（`$` や `$...` を除いた名前部分）。
    MetaVars: TStringArray;
    MetaVarEllipses: TStringArray;
  end;

function DefaultPatLexOptions: TPatLexOptions;
function PreprocessPattern(const Src: string; const Opts: TPatLexOptions): TPatLexResult;

implementation

function DefaultPatLexOptions: TPatLexOptions;
begin
  Result.PascalHexDollar := False;
end;

function PreprocessPattern(const Src: string; const Opts: TPatLexOptions): TPatLexResult;
var
  Dst: string;
  i, Line, Col: Integer;
  SrcLen: Integer;
  j, idx: Integer;
  nStart, nEnd: Integer;
  rStart, rEnd: Integer;
  N, R: string;
  dotCount: Integer;
  identEnd: Integer;
  ident: string;
  hasLower, allHex: Boolean;

  procedure AppendUnique(var Arr: TStringArray; const S: string);
  var
    k: Integer;
  begin
    for k := 0 to High(Arr) do
      if Arr[k] = S then Exit;
    SetLength(Arr, Length(Arr) + 1);
    Arr[Length(Arr) - 1] := S;
  end;

  procedure SetError(const Msg: string; ELine, ECol: Integer);
  begin
    Result.Ok := False;
    Result.Text := '';
    Result.ErrorMessage := Msg;
    Result.ErrorLine := ELine;
    Result.ErrorColumn := ECol;
  end;

  procedure AdvanceByte(c: Char);
  begin
    if c = #10 then
    begin
      Inc(Line);
      Col := 1;
    end
    else
      Inc(Col);
  end;

begin
  Result.Ok := False;
  Result.Text := '';
  Result.ErrorMessage := '';
  Result.ErrorLine := 0;
  Result.ErrorColumn := 0;
  Result.Warnings := nil;
  Result.MetaVars := nil;
  Result.MetaVarEllipses := nil;

  Dst := '';
  i := 1;
  Line := 1;
  Col := 1;
  SrcLen := Length(Src);

  while i <= SrcLen do
  begin
    if Src[i] = '''' then
    begin
      Dst := Dst + Src[i];
      AdvanceByte(Src[i]);
      Inc(i);
      while i <= SrcLen do
      begin
        if Src[i] = #10 then Break;
        if Src[i] = '''' then
        begin
          if (i + 1 <= SrcLen) and (Src[i + 1] = '''') then
          begin
            Dst := Dst + Src[i] + Src[i + 1];
            AdvanceByte(Src[i]);
            AdvanceByte(Src[i + 1]);
            Inc(i, 2);
          end
          else
          begin
            Dst := Dst + Src[i];
            AdvanceByte(Src[i]);
            Inc(i);
            Break;
          end;
        end
        else
        begin
          Dst := Dst + Src[i];
          AdvanceByte(Src[i]);
          Inc(i);
        end;
      end;
    end
    else if Src[i] = '{' then
    begin
      while i <= SrcLen do
      begin
        Dst := Dst + Src[i];
        AdvanceByte(Src[i]);
        Inc(i);
        if (i > 1) and (Src[i - 1] = '}') then Break;
      end;
    end
    else if (i + 1 <= SrcLen) and (Src[i] = '(') and (Src[i + 1] = '*') then
    begin
      // 開きの `(*` を先に写す。ここを閉じの判定に含めると `(*)` を
      // 「開いてすぐ閉じたコメント」と誤認する（Pascal では `(*)` は開きのみ）。
      Dst := Dst + '(*';
      AdvanceByte('(');
      AdvanceByte('*');
      Inc(i, 2);
      while i <= SrcLen do
      begin
        if (Src[i] = '*') and (i + 1 <= SrcLen) and (Src[i + 1] = ')') then
        begin
          Dst := Dst + '*)';
          AdvanceByte('*');
          AdvanceByte(')');
          Inc(i, 2);
          Break;
        end;
        Dst := Dst + Src[i];
        AdvanceByte(Src[i]);
        Inc(i);
      end;
    end
    else if (i + 1 <= SrcLen) and (Src[i] = '/') and (Src[i + 1] = '/') then
    begin
      while i <= SrcLen do
      begin
        if Src[i] = #10 then Break;
        Dst := Dst + Src[i];
        AdvanceByte(Src[i]);
        Inc(i);
      end;
    end
    else if Src[i] = '$' then
    begin
      if (i + 3 <= SrcLen) and (Src[i + 1] = '.') and (Src[i + 2] = '.') and (Src[i + 3] = '.') then
      begin
        nStart := i + 4;
        if (nStart <= SrcLen) and ((Src[nStart] in ['A'..'Z']) or (Src[nStart] = '_')) then
        begin
          nEnd := nStart;
          while (nEnd + 1 <= SrcLen) and ((Src[nEnd + 1] in ['A'..'Z']) or (Src[nEnd + 1] in ['0'..'9']) or (Src[nEnd + 1] = '_')) do
            Inc(nEnd);
          N := Copy(Src, nStart, nEnd - nStart + 1);
          Dst := Dst + MetaVarEllipsisPrefix + N + PlaceholderSuffix;
          AppendUnique(Result.MetaVarEllipses, N);
          for j := i to nEnd do
            AdvanceByte(Src[j]);
          i := nEnd + 1;
        end
        else
        begin
          SetError('`$...` must be followed by a metavariable name of uppercase letters, digits and underscores', Line, Col);
          Exit;
        end;
      end
      else
      begin
        rStart := i + 1;
        rEnd := rStart - 1;
        while (rEnd + 1 <= SrcLen) and ((Src[rEnd + 1] in ['A'..'Z']) or (Src[rEnd + 1] in ['a'..'z']) or (Src[rEnd + 1] in ['0'..'9']) or (Src[rEnd + 1] = '_')) do
          Inc(rEnd);

        if rEnd < rStart then
        begin
          Dst := Dst + '$';
          AdvanceByte(Src[i]);
          Inc(i);
        end
        else
        begin
          R := Copy(Src, rStart, rEnd - rStart + 1);

          if R[1] in ['0'..'9'] then
          begin
            Dst := Dst + '$' + R;
            for j := i to rEnd do
              AdvanceByte(Src[j]);
            i := rEnd + 1;
          end
          else
          begin
            hasLower := False;
            for idx := 1 to Length(R) do
              if R[idx] in ['a'..'z'] then
              begin
                hasLower := True;
                Break;
              end;

            // メタ変数名は大文字のみ（opengrep と同じ）。小文字を含むものは
            // `$ff` のような Pascal の 16 進リテラルとして手を付けずに残し、
            // 綴りが不正ならパース側で読み込みエラーになるのに任せる。
            if hasLower then
            begin
              Dst := Dst + '$' + R;
              for j := i to rEnd do
                AdvanceByte(Src[j]);
              i := rEnd + 1;
            end
            else
            begin
              allHex := True;
              for idx := 1 to Length(R) do
                if not ((R[idx] in ['A'..'F']) or (R[idx] in ['0'..'9'])) then
                begin
                  allHex := False;
                  Break;
                end;

              // `$ABC` はメタ変数とも 16 進リテラルとも読める。推測で片方に倒すと
              // 意図と違うルールが黙って動くので、既定はエラーにする（未決 #3 の決定）。
              if allHex then
              begin
                if Opts.PascalHexDollar then
                begin
                  Dst := Dst + '$' + R;
                  SetLength(Result.Warnings, Length(Result.Warnings) + 1);
                  Result.Warnings[Length(Result.Warnings) - 1] :=
                    Format('%d:%d: `$%s` is kept as a hexadecimal literal (pascal_hex_dollar)', [Line, Col, R]);
                  for j := i to rEnd do
                    AdvanceByte(Src[j]);
                  i := rEnd + 1;
                end
                else
                begin
                  SetError(
                    Format('`$%s` is ambiguous: it reads as both a metavariable and a hexadecimal literal; rename it (e.g. `$X`) or write the literal as `$0%s`', [R, R]),
                    Line, Col);
                  Exit;
                end;
              end
              else
              begin
                Dst := Dst + MetaVarPrefix + R + PlaceholderSuffix;
                AppendUnique(Result.MetaVars, R);
                for j := i to rEnd do
                  AdvanceByte(Src[j]);
                i := rEnd + 1;
              end;
            end;
          end;
        end;
      end;
    end
    else if Src[i] = '.' then
    begin
      dotCount := 0;
      while (i + dotCount <= SrcLen) and (Src[i + dotCount] = '.') do
        Inc(dotCount);

      if dotCount >= 4 then
      begin
        SetError('a run of four or more dots is not a valid pattern', Line, Col);
        Exit;
      end
      else if dotCount = 3 then
      begin
        // `<... e ...>` は M3 の機能。黙って ellipsis 2 個と比較演算子に
        // 読み替えると意味の違うパターンになるので、明示的に断る。
        if (i > 1) and (Src[i - 1] = '<') then
        begin
          SetError('`<... ...>` (deep expression) is not supported yet', Line, Col);
          Exit;
        end
        else
          Dst := Dst + EllipsisPlaceholder;
      end
      else
        Dst := Dst + Copy(Src, i, dotCount);

      for j := 1 to dotCount do
        AdvanceByte(Src[i + j - 1]);
      i := i + dotCount;
    end
    else if (Src[i] in ['A'..'Z']) or (Src[i] in ['a'..'z']) or (Src[i] = '_') then
    begin
      identEnd := i;
      while (identEnd + 1 <= SrcLen) and ((Src[identEnd + 1] in ['A'..'Z']) or (Src[identEnd + 1] in ['a'..'z']) or (Src[identEnd + 1] in ['0'..'9']) or (Src[identEnd + 1] = '_')) do
        Inc(identEnd);

      ident := Copy(Src, i, identEnd - i + 1);

      if (Length(ident) >= Length(ReservedPrefix)) and
         (LowerCase(Copy(ident, 1, Length(ReservedPrefix))) = ReservedPrefix) then
      begin
        SetError(Format('identifier `%s` uses the reserved prefix `__rawpaco_`', [ident]), Line, Col);
        Exit;
      end;

      Dst := Dst + ident;
      for j := i to identEnd do
        AdvanceByte(Src[j]);
      i := identEnd + 1;
    end
    else
    begin
      Dst := Dst + Src[i];
      AdvanceByte(Src[i]);
      Inc(i);
    end;
  end;

  Result.Ok := True;
  Result.Text := Dst;
end;

end.
