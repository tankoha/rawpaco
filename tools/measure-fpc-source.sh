#!/bin/bash
# fpc-source 全体の実測（設計書 OPENGREP_RULE_ENGINE_DESIGN 7.2）。基準値（HANDOFF.md）と同じく
# 200 ファイルずつ rawpaco に渡し、--format=text の出力と各回の終了コードを残す。
# 終了コードを残すのは、2 以上（読み込みエラー・シグナル）でクラッシュを見分けるため。
# usage: tools/measure-fpc-source.sh <出力の接頭辞> [rawpaco の引数...]
set -uo pipefail
out=$1; shift
src=${FPCSRC:-/usr/share/fpcsrc/3.2.2}
start=$(date +%s%N)
find "$src" \( -name '*.pas' -o -name '*.pp' \) -type f | sort |
  xargs -n 200 sh -c './src/rawpaco --format=text "$@"; echo "rc=$?" >&2' rawpaco "$@" \
  > "$out.out" 2> "$out.err"
end=$(date +%s%N)
echo "$(( (end - start) / 1000000 )) ms; exit codes: $(grep -o 'rc=[0-9]*' "$out.err" | sort | uniq -c | tr '\n' ' ')"
grep -o '\[[A-Za-z0-9-]*\]$' "$out.out" | sort | uniq -c
