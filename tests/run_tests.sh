#!/usr/bin/env bash
# tests/positive/<RuleId>/*.pas と tests/negative/<RuleId>/*.pas の各サンプルに
# rawpacoを実行し、診断出力の"[<RuleId>]"タグの有無と終了コードを検証する
# (docs/RULE_ENGINE_DESIGN.md 3節)。fpcunit等は使わず素朴なbash+grepのみで
# 完結させ、Windows CI(Git Bash)でもそのまま動くようにしている。
set -u

cd "$(dirname "$0")/.."

if [ -x "./src/rawpaco.exe" ]; then
  RAWPACO="./src/rawpaco.exe"
elif [ -x "./src/rawpaco" ]; then
  RAWPACO="./src/rawpaco"
else
  echo "run_tests.sh: cannot find built src/rawpaco[.exe]; run 'make' (or the Windows build steps) first" >&2
  exit 1
fi

FAIL=0

check_dir() {
  local kind="$1" want_tag="$2" want_rc="$3" dir rule_id file output rc found
  for dir in "tests/$kind"/*/; do
    [ -d "$dir" ] || continue
    rule_id="$(basename "$dir")"
    for file in "$dir"*.pas; do
      [ -e "$file" ] || continue
      output="$("$RAWPACO" "$file" 2>&1)"; rc=$?
      if echo "$output" | grep -qF "[$rule_id]"; then found=yes; else found=no; fi
      if [ "$found" != "$want_tag" ] || [ "$rc" != "$want_rc" ]; then
        echo "FAIL: $file (rule=$rule_id): expected tag=$want_tag/rc=$want_rc, got tag=$found/rc=$rc"
        echo "$output" | sed 's/^/  /'
        FAIL=1
      else
        echo "ok:   $file"
      fi
    done
  done
}

check_dir positive no  0
check_dir negative yes 1

if [ "$FAIL" -ne 0 ]; then
  echo "run_tests.sh: FAILURES DETECTED"
  exit 1
fi
echo "run_tests.sh: all sample checks passed"
