#!/usr/bin/env bash
# 用与 Gate job 完全相同的判定逻辑，穷举 2024-01-01 ~ 2028-12-31（含 2024/2028 闰年）
# 验证：每月恰好 3 个编译日，且月末那次落在真正的月末（28/29/30/31）。
set -Eeuo pipefail

d="2024-01-01"
declare -A B
while [ "$d" != "2029-01-01" ]; do
  ymd="${d//-/}"; ym="${ymd:0:6}"; day="${ymd:6:2}"
  tomorrow="$(date -u -d "$d +1 day" +%d)"
  build=false; kind=""
  case "$day" in
    10)               build=true; kind=d10;      suffix="${ym}10" ;;
    20)               build=true; kind=d20;      suffix="${ym}20" ;;
    28|29|30|31)
      if [ "$tomorrow" = "01" ]; then build=true; kind=month_end; suffix="$ym"; fi ;;
  esac
  if [ "$build" = "true" ]; then B["$ym"]="${B[$ym]:-} ${day}:${kind}:${suffix}"; fi
  d="$(date -u -d "$d +1 day" +%Y-%m-%d)"
done

fail=0; total=0
for ym in $(printf '%s\n' "${!B[@]}" | sort); do
  set -- ${B[$ym]}
  n=$#
  real_last="$(date -u -d "${ym:0:4}-${ym:4:2}-01 +1 month -1 day" +%d)"
  last_kind=""
  for item in "$@"; do
    case "$item" in ${real_last}:*) last_kind="$item" ;; esac
  done
  total=$((total+1))
  status="OK"
  if [ "$n" -ne 3 ]; then status="FAIL(次数=$n)"; fail=$((fail+1)); fi
  case "$last_kind" in
    *:month_end:*) ;;
    *) status="FAIL(月末=$last_kind)"; fail=$((fail+1)) ;;
  esac
  printf '%s  真实月末=%s日  %s  %s\n' "$ym" "$real_last" "$status" "${B[$ym]}"
done
echo "----"
echo "共验证 $total 个月，失败 $fail 个月"
[ "$fail" -eq 0 ]
