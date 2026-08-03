#!/usr/bin/awk -f
#
# `ppudump -VSD <unit>.ppu` のテキスト出力を解析し、1シンボル1行のTSVを出力する。
#
#   G<TAB><name><TAB><D|.><TAB><deprecation message>   ... ユニットレベルの公開シンボル
#   M<TAB><name>                                        ... それ以外の名前(クラスメンバ等)
#
# なぜppudumpを使うか(CLAUDE.mdルール8):
# fpc-sourceのPascalソースを自前でパースしてシンボルを抜き出す方式も考えられるが、
# RTLのソースは`{$i xxx.inc}`によるinclude・プラットフォーム別の`{$ifdef}`が
# 深く入り組んでおり、正しく展開するには実質的にFPCのプリプロセッサ相当が必要になる。
# 一方 .ppu は「FPC自身がそのソースをコンパイルした結果」であり、公開シンボルと
# deprecatedヒントの権威ある一覧そのものである。ppudumpはFPCに標準同梱される
# 公式ツール(freepascal.orgのドキュメントに記載あり)なので、CLAUDE.mdルール1の
# 「実在確認」も満たす。
#
# ppudumpの出力構造(FPC 3.2.2の実機出力で確認):
#   - セクションは "Interface definitions" → "Interface Symbols" →
#     "Interface Macro Symbols" → "Implementation symtable" の順に並ぶ。
#     implementation側は非公開なので "Interface Macro Symbols" 以降は読まない。
#   - deprecated情報の在り処が2種類ある。変数・定数・型は symbol 側の
#     `SymOptions : Hint Deprecated` に出るが、手続き・関数は symbol 側ではなく
#     definition 側(`Procedure definition` ブロックの `SymOptions`)に出る。
#     symbolの `Definition : (n) DefId d` で辿って突き合わせる必要がある。

BEGIN { section = "none" }

/^Interface definitions$/   { section = "defs"; next }
/^Interface Symbols$/       { section = "syms"; next }
/^Interface Macro Symbols$/ { section = "done"; next }
/^Implementation symtable$/ { section = "done"; next }

section == "defs" {
  # definition ブロックはネストする(クラスのメソッドは obj definition の中に入る)。
  # DefId はユニット内で一意なのでインデントを問わず記録してよい。
  if ($0 ~ /^ *\*\* Definition Id [0-9]+ \*\*$/) {
    match($0, /[0-9]+/); curdef = substr($0, RSTART, RLENGTH); seenopt = 0; next
  }
  # ブロック内には引数シンボル(parast)の SymOptions も現れるため、
  # ヘッダ直後の最初の SymOptions だけをそのdefinition自身のものとして扱う。
  if (curdef != "" && !seenopt && $0 ~ /^ *SymOptions *: /) {
    seenopt = 1
    if ($0 ~ /Deprecated/) depdef[curdef] = 1
    next
  }
  if (curdef != "" && $0 ~ /^ *Deprecated *: /) {
    msg = $0; sub(/^ *Deprecated *: /, "", msg); depmsg[curdef] = msg
    next
  }
  # クラスメンバ等、ユニットレベルではない名前も「既知の名前」として拾っておく
  # (P7の緩い判定で「見たことのない名前」を絞り込むために使う。過剰に含めても
  #  検知漏れ方向にしか働かないので安全側)。
  if ($0 ~ / symbol /) { emitLoose($0) }
  next
}

section == "syms" {
  if ($0 ~ /^\*\* Symbol Id [0-9]+ \*\*$/) { flushSym(); expectname = 1; next }
  if (expectname) {
    expectname = 0
    if ($0 ~ / symbol /) {
      kind = $0; sub(/ symbol .*$/, "", kind)
      name = $0; sub(/^.* symbol /, "", name)
      have = 1
    }
    next
  }
  if (!have) next
  if ($0 ~ /^ *Visibility *: /) { vis = $0; sub(/^ *Visibility *: /, "", vis); next }
  if ($0 ~ /^ *SymOptions *: /) { if ($0 ~ /Deprecated/) owndep = 1; next }
  if ($0 ~ /^ *Deprecated *: /) { m = $0; sub(/^ *Deprecated *: /, "", m); ownmsg = m; next }
  if ($0 ~ /^ *Definition *: .*DefId [0-9]+/) {
    d = $0; sub(/^.*DefId /, "", d); sub(/[^0-9].*$/, "", d)
    ndefs++; defs[ndefs] = d
    next
  }
}

function emitLoose(line,   n) {
  n = line; sub(/^.* symbol /, "", n)
  if (isIdent(n)) print "M\t" n
}

function isIdent(s) { return (s ~ /^[A-Za-z_][A-Za-z0-9_]*$/) }

function flushSym(   i, dep, msg, alldep) {
  if (!have) { resetSym(); return }
  # 'Unit symbol' はユニット自身の名前とuses一覧であってエクスポートではない。
  # コンパイラ内部名($ansistrrec1 等)はPascal識別子として書けないので除外する。
  if (kind != "Unit" && vis == "public" && isIdent(name)) {
    dep = owndep; msg = ownmsg
    if (!dep && ndefs > 0) {
      # オーバーロードがある場合、全ての定義がdeprecatedのときだけdeprecated扱いに
      # する(片方だけ非推奨の名前を一律に警告すると誤検知になるため。
      # CLAUDE.mdルール5)。
      alldep = 1
      for (i = 1; i <= ndefs; i++) if (!(defs[i] in depdef)) alldep = 0
      if (alldep) {
        dep = 1
        for (i = 1; i <= ndefs; i++) if ((defs[i] in depmsg) && msg == "") msg = depmsg[defs[i]]
      }
    }
    gsub(/\t/, " ", msg)
    printf "G\t%s\t%s\t%s\n", name, (dep ? "D" : "."), msg
  }
  resetSym()
}

function resetSym() { have = 0; kind = ""; name = ""; vis = ""; owndep = 0; ownmsg = ""; ndefs = 0; delete defs }

END { flushSym() }
