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

# --only/--exclude の配線を確認する。DEFENSE-001とSEC-001それぞれを検知する
# 2ファイルを同時に渡し、フィルタで片方だけが黙ることを見る。
flag_case() {
  local desc="$1" flag="$2" want_rc="$3"; shift 3
  local want_tags=("$@")
  local output rc tag found all_ok=1
  output="$("$RAWPACO" "$flag" "$NEG_DEFENSE" "$NEG_SEC001" 2>&1)"; rc=$?
  for tag in "RAWPACO-DEFENSE-001" "RAWPACO-SEC-001"; do
    if echo "$output" | grep -qF "[$tag]"; then found=yes; else found=no; fi
    local want=no
    for w in "${want_tags[@]}"; do [ "$w" = "$tag" ] && want=yes; done
    if [ "$found" != "$want" ]; then
      echo "FAIL: flag case '$desc': expected $tag tag=$want, got $found"
      all_ok=0
    fi
  done
  if [ "$rc" != "$want_rc" ]; then
    echo "FAIL: flag case '$desc': expected rc=$want_rc, got rc=$rc"
    all_ok=0
  fi
  if [ "$all_ok" = 1 ]; then
    echo "ok:   flag case '$desc'"
  else
    echo "$output" | sed 's/^/  /'
    FAIL=1
  fi
}

flag_error_case() {
  local desc="$1" want_rc="$2"; shift 2
  local output rc
  output="$("$RAWPACO" "$@" "$NEG_DEFENSE" 2>&1)"; rc=$?
  if [ "$rc" != "$want_rc" ]; then
    echo "FAIL: flag error case '$desc': expected rc=$want_rc, got rc=$rc"
    echo "$output" | sed 's/^/  /'
    FAIL=1
  else
    echo "ok:   flag error case '$desc'"
  fi
}

# 設定ファイル(--config)の配線を確認する。RAWPACO-STYLE-001 は設定で挙動が
# 変わる唯一のルールなので、サンプルの走査だけでは設定の読み込み経路が
# 一度も通らない。Windows 側でも fcl-json が実際に動くことをここで担保する。
config_case() {
  local desc="$1" cfg="$2" target="$3" want_tag="$4" want_rc="$5" output rc found
  output="$("$RAWPACO" --config="$cfg" "$target" 2>&1)"; rc=$?
  if echo "$output" | grep -qF "[RAWPACO-STYLE-001]"; then found=yes; else found=no; fi
  if [ "$found" != "$want_tag" ] || [ "$rc" != "$want_rc" ]; then
    echo "FAIL: config case '$desc': expected tag=$want_tag/rc=$want_rc, got tag=$found/rc=$rc"
    echo "$output" | sed 's/^/  /'
    FAIL=1
  else
    echo "ok:   config case '$desc'"
  fi
}

NEG_STYLE=tests/negative/RAWPACO-STYLE-001/type_names_without_prefix.pas
POS_STYLE=tests/positive/RAWPACO-STYLE-001/conventional_names.pas
NEG_DEFENSE=tests/negative/RAWPACO-DEFENSE-001/empty_except.pas
NEG_SEC001=tests/negative/RAWPACO-SEC-001/sql_concat_lhs_literal.pas

flag_case '--only keeps just the listed rule'    --only=RAWPACO-DEFENSE-001    1 RAWPACO-DEFENSE-001
flag_case '--exclude drops just the listed rule' --exclude=RAWPACO-DEFENSE-001 1 RAWPACO-SEC-001
flag_error_case 'unknown --only id'            2 --only=RAWPACO-NOPE
flag_error_case 'unknown --exclude id'         2 --exclude=RAWPACO-NOPE
flag_error_case '--only and --exclude together' 2 --only=RAWPACO-DEFENSE-001 --exclude=RAWPACO-SEC-001
flag_error_case 'empty --only value'           2 --only=
flag_error_case 'empty --exclude value'        2 --exclude=
# 回帰テスト(Fable5のレビューで発見): 空値チェックが元々ループ完了後の
# 「両方とも空か」だけを見ており、片方だけ空でもう片方に値がある場合に
# すり抜けるバグがあった。フラグごとに独立してチェックするよう修正済み。
flag_error_case 'empty --only value with non-empty --exclude'   2 --only= --exclude=RAWPACO-DEFENSE-001
flag_error_case 'empty --exclude value with non-empty --only'   2 --exclude= --only=RAWPACO-DEFENSE-001

# naming.enabled=false でルール全体が黙る
config_case 'naming disabled'        tests/config/naming_disabled.json "$NEG_STYLE" no  0
# 接頭辞を差し替えると、既定では通るコードが逆に警告される
config_case 'custom prefixes'        tests/config/custom_prefixes.json "$POS_STYLE" yes 1
# false / null を指定したカテゴリは黙る（record は null なので MyRecord は出ない）
config_case 'disabled categories'    tests/config/custom_prefixes.json "$NEG_STYLE" yes 1
# 設定ファイルの誤りは黙って無視せずエラー終了(2)にする
config_case 'unknown key is an error' tests/config/broken.json         "$POS_STYLE" no  2

if [ "$FAIL" -ne 0 ]; then
  echo "run_tests.sh: FAILURES DETECTED"
  exit 1
fi
echo "run_tests.sh: all sample checks passed"
