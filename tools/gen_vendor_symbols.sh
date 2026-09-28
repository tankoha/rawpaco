#!/usr/bin/env bash
#
# vendoring した第三者ライブラリのシンボル一覧を生成する。
# 生成物は data/vendor-<name>-symbols.txt で、src/FPCSymbols.pas が
# data/fpc-rtl-symbols.txt と一緒に読み込む。
#
#   usage: bash tools/gen_vendor_symbols.sh <name> <source-dir> [fpc-flags...]
#
#   例: bash tools/gen_vendor_symbols.sh horse vendor/horse/src -Mdelphi
#
# なぜ RTL 用 (tools/gen_fpc_symbols.sh) と別スクリプトなのか（CLAUDE.mdルール8）:
# RTL 側は「OS が配置済みの .ppu を ppudump にかける」だけで済むが、第三者
# ライブラリは .ppu が存在しないため**まず fpc でコンパイルする**必要がある。
# コンパイルに必要なフラグ（モード・検索パス・定義）はライブラリごとに違うので
# 引数で受け取る。シンボル抽出そのもの（ppudump の出力解析）は RTL 側と完全に
# 同じ tools/ppudump_symbols.awk / tools/source_idents.awk を使う。
#
# ■ strict / loose の方針（重要）
#
# 生成される U 行は **必ず loose** にしてある。RAWPACO-HALLUC-001 の判定A
# （「ユニット修飾された参照がそのユニットのシンボル一覧に無ければ報告する」）は
# strict なユニットに対してのみ働くため、抽出の網羅性に確信が持てないうちに
# strict にすると「実在する API を実在しないと言う」最悪の誤検知になる。
#
# 手順としては、
#   1. loose で取り込む（この段階でも「usesが全て既知ユニット」という判定Bの
#      門番を通せるようになるので、それだけで効果がある）
#   2. そのライブラリを使う実コードに当てて誤検知ゼロを実測する
#   3. 確認できたら生成物の U 行を手で strict に変える、あるいは本スクリプトに
#      strict 指定のオプションを足す
# という2段運用を推奨する。詳細は docs/RULE_ENGINE_DESIGN.md 2.3節。
#
# ■ 生成物をコミットする理由
#
# tools/gen_fpc_symbols.sh と同じ（.ppu はターゲット OS/CPU ごとに内容が変わり、
# CI 環境で再生成すると lint 結果が環境で変わってしまう）。生成に使った
# ライブラリのバージョンを HANDOFF.md とデータファイルのヘッダに明記する。

set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$#" -lt 2 ]; then
  echo "usage: bash tools/gen_vendor_symbols.sh <name> <source-dir> [fpc-flags...]" >&2
  exit 2
fi

NAME="$1"; shift
SRC_DIR="$1"; shift
FPC_FLAGS=("$@")

if [ ! -d "$SRC_DIR" ]; then
  echo "gen_vendor_symbols.sh: no such directory: $SRC_DIR" >&2
  exit 1
fi

OUT="data/vendor-$NAME-symbols.txt"
FPC_VER="$(fpc -iV)"
FPC_TARGET="$(fpc -iTP)-$(fpc -iTO)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ライブラリを丸ごとコンパイルして .ppu を作る。ユニット間の依存順は fpc に
# 解決させるため、各ユニットを個別に -B なしでコンパイルし、失敗は記録して続ける
# （相互依存や未解決の外部依存で一部が落ちても、通ったユニット分は使えるため）。
mkdir -p "$TMP/units"
FAILED=""
COMPILED=0
# `<(...)` のプロセス置換は Bash 専用なので使わず、tools/gen_fpc_symbols.sh と
# 同じく一時ファイルに落としてから読む。
find "$SRC_DIR" \( -name '*.pas' -o -name '*.pp' \) -type f | sort > "$TMP/srcfiles"
while IFS= read -r F; do
  [ -n "$F" ] || continue
  if fpc "${FPC_FLAGS[@]}" -FU"$TMP/units" -Fu"$SRC_DIR" -Fi"$SRC_DIR" \
         -o"$TMP/units/$(basename "$F").out" "$F" > "$TMP/fpc.log" 2>&1; then
    COMPILED=$((COMPILED + 1))
  else
    FAILED="$FAILED $(basename "$F")"
  fi
done < "$TMP/srcfiles"

if [ "$COMPILED" -eq 0 ]; then
  echo "gen_vendor_symbols.sh: no unit compiled successfully; check the fpc flags" >&2
  echo "  last fpc output:" >&2
  sed 's/^/    /' "$TMP/fpc.log" >&2
  exit 1
fi

{
  echo "# rawpaco: vendored library symbol table ($NAME)"
  echo "# DO NOT EDIT BY HAND. Regenerate with:"
  echo "#   bash tools/gen_vendor_symbols.sh $NAME $SRC_DIR ${FPC_FLAGS[*]}"
  echo "# fpc-version: $FPC_VER"
  echo "# generated-from-target: $FPC_TARGET"
  echo "# source-root: $SRC_DIR"
  echo "#"
  echo "# Format is identical to data/fpc-rtl-symbols.txt (see that file's header)."
  echo "# All units are emitted as 'loose' on purpose; see this script's comments."
} > "$TMP/out"

for PPU in "$TMP/units"/*.ppu; do
  [ -e "$PPU" ] || continue
  UNAME="$(basename "$PPU" .ppu)"
  ppudump -VSD "$PPU" 2>/dev/null | awk -f tools/ppudump_symbols.awk > "$TMP/raw" || true

  printf 'U\t%s\tloose\n' "$UNAME" >> "$TMP/out"
  awk -F'\t' '$1=="G"' "$TMP/raw" | sort -u -t"$(printf '\t')" -k2,2 >> "$TMP/out"

  awk -F'\t' '$1=="G"{print tolower($2)}' "$TMP/raw" | sort -u > "$TMP/gnames"
  awk -F'\t' '$1=="M"{print tolower($2)}' "$TMP/raw" | sort -u \
    | comm -23 - "$TMP/gnames" \
    | awk 'NF { printf "M\t%s\n", $0 }' >> "$TMP/out"
done

mkdir -p "$(dirname "$OUT")"
mv "$TMP/out" "$OUT"

echo "gen_vendor_symbols.sh: wrote $OUT ($(wc -l < "$OUT") lines, $COMPILED units compiled)"
[ -z "$FAILED" ] || echo "gen_vendor_symbols.sh: NOTE: these units did not compile and are absent:$FAILED" >&2
