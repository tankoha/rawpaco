#!/usr/bin/awk -f
#
# Pascalソースの interface 部に現れる識別子らしきトークンを全て抜き出す。
#
# なぜこれが必要か(CLAUDE.mdルール8):
# .ppu から取れるのは「生成に使ったFPCのターゲットOS/CPUでコンパイルした結果」
# だけである。例えば SysUtils は Windows でのみ Win32MajorVersion / Win32Check /
# EWin32Error 等を公開する（rtl/win/sysutils.pp）。Linux で生成した一覧だけを
# 使うと、Windows専用シンボルへの参照を「存在しない」と誤検知してしまう。
# そこで fpc-source 側の各プラットフォーム版ソースの interface 部から識別子を
# 総なめして「既知の名前」の緩い集合(M)に足し込む。M は警告を抑制する方向にしか
# 効かないので、多めに拾っても誤検知は増えず検知漏れが増えるだけであり、
# CLAUDE.mdルール5(疑わしきは見逃す)に沿う。
#
# コメント・文字列リテラルは除去してから走査する。includeされる .inc の中身は
# 追わない（プラットフォーム非依存の共通部分は .ppu 側で既に取れているため）。

BEGIN { IGNORECASE = 1; inbrace = 0; inparen = 0 }

{
  line = $0

  # 行コメント
  sub(/\/\/.*$/, "", line)

  # ブレースコメント {...} と (*...*) を素朴に除去する。
  out = ""
  i = 1
  n = length(line)
  while (i <= n) {
    c = substr(line, i, 1)
    if (inbrace) { if (c == "}") inbrace = 0; i++; continue }
    if (inparen) { if (substr(line, i, 2) == "*)") { inparen = 0; i += 2 } else i++; continue }
    if (c == "{") { inbrace = 1; i++; continue }
    if (substr(line, i, 2) == "(*") { inparen = 1; i += 2; continue }
    if (c == "'") {
      i++
      while (i <= n && substr(line, i, 1) != "'") i++
      i++
      continue
    }
    out = out c
    i++
  }

  if (out ~ /^[ \t]*implementation[ \t]*$/) exit

  while (match(out, /[A-Za-z_][A-Za-z0-9_]*/)) {
    print substr(out, RSTART, RLENGTH)
    out = substr(out, RSTART + RLENGTH)
  }
}
