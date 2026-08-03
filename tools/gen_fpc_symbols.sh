#!/usr/bin/env bash
#
# data/fpc-rtl-symbols.txt を再生成する。
#
# 生成物はリポジトリにコミットして使う（動的生成しない）。理由（CLAUDE.mdルール2の
# バージョン固定方針と同じ発想。ルール8に従い「なぜ」を残す）:
#
#   1. Windows CI は choco の freepascal パッケージを使っているが、fpc-source が
#      同梱されているかは不明で、これまでも標準ライブラリの一部が見つからない事例が
#      複数あった（HANDOFF.md 参照）。CI 実行のたびに再生成する方式は成立しない
#      可能性が高い。
#   2. .ppu はターゲット OS/CPU ごとに内容が変わる。CI の Linux(x86_64) と
#      Windows(i386) でそれぞれ生成すると、同じソースに対する lint 結果が OS で
#      変わってしまい再現性がない。生成物を1つコミットしておけば、どの環境でも
#      同じ判定になる。
#   3. 生成に使った FPC のバージョンを HANDOFF.md / データファイルのヘッダに
#      明記でき、tree-sitter-pascal のピン留めと同じレベルの再現性が得られる。
#
# 実行には fpc-source パッケージと ppudump（FPC 同梱）が必要。Linux 前提。
#
#   usage: bash tools/gen_fpc_symbols.sh [出力先]

set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-data/fpc-rtl-symbols.txt}"

FPC_VER="$(fpc -iV)"
FPC_TARGET="$(fpc -iTP)-$(fpc -iTO)"

# find に存在しないディレクトリを渡すと終了コード1になり、pipefail + set -e で
# スクリプトごと止まってしまうため、実在するディレクトリだけを対象にする。
find_first() {
  local pat="$1"; shift
  local d out
  for d in "$@"; do
    [ -d "$d" ] || continue
    out="$(find "$d" -name "$pat" 2>/dev/null | head -1)"
    if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  done
  return 0
}

UNITS_ROOT="$(find_first 'system.ppu' /usr/lib /usr/local/lib /usr/lib64)"
[ -z "$UNITS_ROOT" ] || UNITS_ROOT="$(dirname "$(dirname "$UNITS_ROOT")")"
SRC_ROOT=""
for d in /usr/share/fpcsrc /usr/local/share/fpcsrc; do
  [ -d "$d/$FPC_VER" ] && SRC_ROOT="$d/$FPC_VER" && break
done

if [ ! -d "$UNITS_ROOT" ]; then echo "gen_fpc_symbols.sh: cannot locate FPC .ppu unit tree" >&2; exit 1; fi
if [ ! -d "$SRC_ROOT" ];   then echo "gen_fpc_symbols.sh: cannot locate fpc-source tree (install fpc-source)" >&2; exit 1; fi

# 対象ユニット一覧。「FPC/Lazarus で書かれた一般的なアプリケーションが実際に
# uses しうる、クロスプラットフォームな RTL/FCL ユニット」を人手で選定した。
# ここに載っていないユニット（サードパーティ、LCL、プラットフォーム専用の
# windows/baseunix/unix 等）は rawpaco から見て「未知のユニット」であり、
# RAWPACO-HALLUC-001 はそれらを uses しているファイルでは何も報告しない。
#
# 2列目:
#   strict … このユニットの公開シンボル一覧は網羅的とみなし、
#            RAWPACO-HALLUC-001 の「ユニット修飾された参照」判定に使う。
#   loose  … 公開シンボルがプラットフォーム別 include で組み立てられており
#            網羅性を保証できないため、判定には使わない（deprecated 検知と
#            「既知の名前」集合には引き続き使う）。
UNIT_LIST='
system loose
sysutils strict
classes strict
math strict
types strict
typinfo strict
character strict
strings strict
strutils strict
dateutils strict
variants strict
varutils strict
convutils strict
rtti strict
fmtbcd strict
nullable strict
fgl strict
rtlconsts strict
sysconst strict
getopts strict
dos loose
generics.collections strict
generics.defaults strict
generics.strings strict
contnrs strict
inifiles strict
syncobjs strict
avl_tree strict
base64 strict
bufstream strict
custapp strict
eventlog strict
iostream strict
streamex strict
streamio strict
uriparser strict
maskutils strict
pooledmm strict
rttiutils strict
gettext strict
ascii85 strict
blowfish strict
idea strict
csvdocument strict
csvreadwrite strict
fpexprpars strict
fptemplate strict
fptimer strict
inicol strict
nullstream strict
streamcoll strict
cachecls strict
fpobserver strict
fpjson strict
jsonparser strict
jsonscanner strict
jsonreader strict
jsonconf strict
fpjsonrtti strict
process strict
pipes strict
dom strict
xmlread strict
xmlwrite strict
xmlutils strict
xmlconf strict
xpath strict
'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

{
  echo "# rawpaco: FPC RTL/FCL symbol table"
  echo "# DO NOT EDIT BY HAND. Regenerate with: bash tools/gen_fpc_symbols.sh"
  echo "# fpc-version: $FPC_VER"
  echo "# generated-from-target: $FPC_TARGET"
  echo "# ppu-root: $UNITS_ROOT"
  echo "# source-root: $SRC_ROOT"
  echo "#"
  echo "# Format (tab separated):"
  echo "#   U <unit> <strict|loose>   ... start of a unit block"
  echo "#   G <name> <D|.> <message>  ... unit-level public symbol (D = deprecated)"
  echo "#   M <name>                  ... other known name (class member, platform-only, ...)"
} > "$TMP/out"

MISSING=""
while read -r UNAME UMODE; do
  [ -n "${UNAME:-}" ] || continue
  PPU="$(find "$UNITS_ROOT" -name "$UNAME.ppu" | head -1)"
  if [ -z "$PPU" ]; then MISSING="$MISSING $UNAME"; continue; fi

  ppudump -VSD "$PPU" 2>/dev/null | awk -f tools/ppudump_symbols.awk > "$TMP/raw"

  # プラットフォーム別ソースからの補完（tools/source_idents.awk 冒頭のコメント参照）。
  : > "$TMP/srcids"
  find "$SRC_ROOT" \( -name "$UNAME.pp" -o -name "$UNAME.pas" \) 2>/dev/null > "$TMP/srcfiles" || true
  NSRC="$(wc -l < "$TMP/srcfiles")"
  while IFS= read -r F; do
    [ -n "$F" ] || continue
    awk -f tools/source_idents.awk "$F" >> "$TMP/srcids" || true
    # ソースがプラットフォームごとに複数存在するユニット(system/sysutils/dos等)は、
    # 公開宣言の実体が同じディレクトリの *h.inc に切り出されている。この場合だけ
    # *h.inc も舐める。単一実装のユニットで無条件に舐めると、たまたま同じ
    # ディレクトリにある無関係な宣言ファイル(rtl/inc/*h.inc 等)まで巻き込んで
    # 「既知の名前」集合が無駄に膨らみ、検知漏れが増えるため。
    if [ "$NSRC" -gt 1 ]; then
      for H in "$(dirname "$F")"/*h.inc; do
        [ -e "$H" ] || continue
        awk -f tools/source_idents.awk "$H" >> "$TMP/srcids" || true
      done
    fi
  done < "$TMP/srcfiles"

  printf 'U\t%s\t%s\n' "$UNAME" "$UMODE" >> "$TMP/out"
  # grep は一致0件で終了コード1を返し pipefail に引っかかるため awk を使う。
  awk -F'\t' '$1=="G"' "$TMP/raw" | sort -u -t"$(printf '\t')" -k2,2 >> "$TMP/out"

  # M は G に無いものだけを出す（重複を持たせても意味がないため）。
  # 照合は大文字小文字を無視するので、M 側は小文字に正規化して重複を潰す。
  awk -F'\t' '$1=="G"{print tolower($2)}' "$TMP/raw" | sort -u > "$TMP/gnames"
  {
    awk -F'\t' '$1=="M"{print tolower($2)}' "$TMP/raw"
    tr 'A-Z' 'a-z' < "$TMP/srcids"
  } | sort -u | comm -23 - "$TMP/gnames" \
    | awk 'NF { printf "M\t%s\n", $0 }' >> "$TMP/out"
done <<< "$UNIT_LIST"

mkdir -p "$(dirname "$OUT")"
mv "$TMP/out" "$OUT"

echo "gen_fpc_symbols.sh: wrote $OUT ($(wc -l < "$OUT") lines)"
[ -z "$MISSING" ] || echo "gen_fpc_symbols.sh: WARNING: .ppu not found for:$MISSING" >&2
