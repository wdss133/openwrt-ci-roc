#!/usr/bin/env bash
# 用假的 gh 命令离线跑 release.sh，验证发布/清理逻辑：
#   本月 10/20 快照保留；上月 10/20 快照删除；月末归档保留 36 期；上游 IPQ807X 绝不触碰。
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/art"
printf 'luci-app-uhttpd 1.0 - -\n' > "$T/art/x.manifest"
printf '| p | v | d | r |\n' > "$T/art/x.plugins.md"
printf 'firmware-bytes\n' > "$T/art/fw.bin"

cat > "$T/tags" <<'EOF'
IPQ807X-Custom-latest
IPQ807X-Custom-20261110
IPQ807X-Custom-20261120
IPQ807X-Custom-202611
IPQ807X-Custom-20261010
IPQ807X-Custom-20261020
IPQ807X-Custom-202610
IPQ807X-Custom-202609
IPQ807X-Custom-20260810
IPQ807X-Custom
IPQ807X
EOF

cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "release list") cat "$MOCK_TAGS" ;;
  "release view")
    grep -qx -- "$3" "$MOCK_TAGS" && exit 0 || exit 1 ;;
  "release create"|"release edit"|"release upload")
    printf '%s %s\n' "$1" "$2" >> "$MOCK_LOG" ;;
  "release delete")
    printf '%s\n' "$3" >> "$MOCK_DELETED" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/bin/gh"

export MOCK_TAGS="$T/tags" MOCK_LOG="$T/log" MOCK_DELETED="$T/deleted"
: > "$MOCK_LOG"; : > "$MOCK_DELETED"
export PATH="$T/bin:$PATH" GH_TOKEN=fake GITHUB_REPOSITORY=wdss133/test
export ARCHIVE_TAG=IPQ807X-Custom-20261120 BUILD_YM=202611 BUILD_KIND=d20 VERSION_KERNEL=6.12

echo "===== 场景 A：KEEP_SNAPSHOTS=none（默认，上月只留月末）"
KEEP_SNAPSHOTS=none bash "$HERE/release.sh" "$T/art" IPQ807X-Custom 36 > "$T/out" 2>&1 || { cat "$T/out"; exit 1; }
grep -E '^\[release\]' "$T/out"
DEL_A="$(sort "$MOCK_DELETED")"
echo "-- 被删除的 tag:"; echo "$DEL_A"

echo
echo "===== 场景 B：KEEP_SNAPSHOTS=20（额外保留历史 20 日快照）"
: > "$MOCK_DELETED"
KEEP_SNAPSHOTS=20 bash "$HERE/release.sh" "$T/art" IPQ807X-Custom 36 > "$T/out2" 2>&1 || { cat "$T/out2"; exit 1; }
DEL_B="$(sort "$MOCK_DELETED")"
echo "-- 被删除的 tag:"; echo "$DEL_B"

echo
echo "===== 断言"
check() { if eval "$1"; then echo "  PASS: $2"; else echo "  FAIL: $2"; exit 1; fi; }
check "echo \"\$DEL_A\" | grep -qx 'IPQ807X-Custom-20261010'" '上月 10 日快照被清理'
check "echo \"\$DEL_A\" | grep -qx 'IPQ807X-Custom-20261020'" '上月 20 日快照被清理'
check "! echo \"\$DEL_A\" | grep -qx 'IPQ807X-Custom-20261110'" '本月 10 日快照保留'
check "! echo \"\$DEL_A\" | grep -qx 'IPQ807X-Custom-20261120'" '本月 20 日快照保留'
check "! echo \"\$DEL_A\" | grep -qx 'IPQ807X-Custom-202610'" '上月月末归档保留'
check "! echo \"\$DEL_A\" | grep -qx 'IPQ807X'" '上游 IPQ807X 未被触碰'
check "echo \"\$DEL_A\" | grep -qx 'IPQ807X-Custom'" '裸旧 tag 被清理'
check "! echo \"\$DEL_B\" | grep -qx 'IPQ807X-Custom-20261020'" 'KEEP_SNAPSHOTS=20 时历史 20 日快照保留'
echo "全部断言通过"
