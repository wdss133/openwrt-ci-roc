#!/usr/bin/env bash
#
# release.sh —— IPQ807X 定制固件「发布」脚本（与 workflow 解耦，便于 fork / 换分支复用）
#
# 编译节奏：每月 3 次 —— 10 日、20 日、当月最后一天（月末由 Gate 判定，适配 28/29/30/31 天）。
#
# 职责：
#   1) 生成发布说明：区分「默认内置」/「本分支新添加内置」，插件表两段式
#   2) 发布/更新两个 Release：
#        - <PREFIX>-latest          滚动最新（下载链接固定，每次编译都更新）
#        - ${ARCHIVE_TAG}           本次归档，由 Gate 传入：
#              <PREFIX>-YYYYMM10    10 日快照（仅当月保留）
#              <PREFIX>-YYYYMM20    20 日快照（仅当月保留）
#              <PREFIX>-YYYYMM      月末归档（长期保留）
#              <PREFIX>-YYYYMMDD    手动触发的临时快照
#   3) 清理旧 Release：
#        - latest 常驻
#        - 最近 KEEP_MONTHS 个 -YYYYMM 月度归档（默认 36 = 3 年）
#        - 本月的 -YYYYMMDD 快照（跨月自动删除 → 上月只留下月末那一份）
#        - 绝不触碰上游其它 tag（如 IPQ807X）
#
# 用法：
#   release.sh <artifact_dir> [tag_prefix] [keep_months]
# 环境变量：
#   GH_TOKEN            必填（contents:write）
#   GITHUB_REPOSITORY   必填（owner/repo）；本地调试可用 REPO 覆盖
#   ARCHIVE_TAG         可选，本次归档的完整 tag；缺省退回 <PREFIX>-$(date -u +%Y%m)（兼容旧调用）
#   BUILD_YM            可选，本次编译所属 YYYYMM（用于判定"本月快照"）；缺省用当前 UTC 月份
#   BUILD_KIND          可选，d10 / d20 / month_end / manual，仅影响发布说明文案
#   KEEP_SNAPSHOTS      可选，默认 none（上月只留月末）；设为 20 时额外保留最近 KEEP_MONTHS 个月的 20 日快照
#   VERSION_KERNEL / SOURCE_BRANCH / NEW_LUCI   可选，写入发布说明
#
set -Eeuo pipefail

ART_DIR="${1:?用法: release.sh <artifact_dir> [tag_prefix] [keep_months]}"
PREFIX="${2:-IPQ807X-Custom}"
KEEP_MONTHS="${3:-36}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
SOURCE_BRANCH="${SOURCE_BRANCH:-25.12-nss}"
VERSION_KERNEL="${VERSION_KERNEL:-unknown}"
NEW_LUCI="${NEW_LUCI:- luci-app-easytier luci-app-zerotier luci-app-ddns-go luci-app-store luci-app-wechatpush }"
BUILD_KIND="${BUILD_KIND:-manual}"
BUILD_YM="${BUILD_YM:-$(date -u +%Y%m)}"
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-none}"

ADDED_NAMES="${ADDED_NAMES:-kmod-tun、EasyTier、ZeroTier、ddns-go、iStore、wechatpush}"

log() { printf '[release] %s\n' "$*"; }
die() { printf '[release][error] %s\n' "$*" >&2; exit 1; }

[ -d "$ART_DIR" ] || die "artifact 目录不存在: $ART_DIR"
[ -n "$REPO" ] || die "需要 GITHUB_REPOSITORY（或 REPO）"
command -v gh >/dev/null 2>&1 || die "未找到 gh CLI"

NOW="$(date -u '+%Y-%m-%d %H:%M UTC')"
LATEST_TAG="${PREFIX}-latest"
ARCHIVE_TAG="${ARCHIVE_TAG:-${PREFIX}-$(date -u +%Y%m)}"
case "$ARCHIVE_TAG" in "${PREFIX}"-*) ;; *) die "ARCHIVE_TAG 必须以 ${PREFIX}- 开头: $ARCHIVE_TAG" ;; esac
[ "$ARCHIVE_TAG" != "$LATEST_TAG" ] || die "ARCHIVE_TAG 不能等于 latest"

case "$BUILD_KIND" in
  d10)        ARCHIVE_DESC="10 日快照（仅当月保留，跨月自动清理）"; ARCHIVE_TITLE="${ARCHIVE_TAG}（月度快照 · 10 日）" ;;
  d20)        ARCHIVE_DESC="20 日快照（仅当月保留，跨月自动清理）"; ARCHIVE_TITLE="${ARCHIVE_TAG}（月度快照 · 20 日）" ;;
  month_end)  ARCHIVE_DESC="月末归档（长期保留，共 ${KEEP_MONTHS} 期 ≈ 3 年）"; ARCHIVE_TITLE="${ARCHIVE_TAG}（月度归档 · 月末）" ;;
  *)          ARCHIVE_DESC="手动编译快照（仅当月保留）"; ARCHIVE_TITLE="${ARCHIVE_TAG}（手动编译）" ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

############################ 1) 组装发布说明 ############################

ADDED_TABLE="$(cat "$ART_DIR"/*.plugins.md 2>/dev/null || echo '（未采集到本分支插件信息）')"
MAN="$(ls "$ART_DIR"/*.manifest 2>/dev/null | head -n1 || true)"

def_list=""; def_table=""
if [ -n "$MAN" ]; then
  while read -r name ver; do
    [ -n "$name" ] || continue
    case "$name" in
      luci-app-*|luci-theme-*) ;;
      *) continue ;;
    esac
    case "$NEW_LUCI" in *" $name "*) continue ;; esac
    def_list="${def_list:+${def_list}、}${name}"
    def_table="${def_table}| ${name} | ${ver} | （随上游 feeds） | openwrt feeds |\n"
  done < <(awk 'NF>=3{print $1, $3}' "$MAN" 2>/dev/null || true)
else
  log "警告：未找到 *.manifest，默认内置清单将为空"
fi

BODY="$WORK/body.md"
{
  echo "> 🔗 **滚动 latest**（\`${LATEST_TAG}\`）：下载链接固定，每次编译后更新为最新成果。"
  echo "> 📅 **编译节奏**：每月仅 3 次 —— **10 日、20 日、当月最后一天**（自动适配 28/29/30/31 天与闰年），北京时间 21:00。"
  echo "> 📦 **本次归档**（\`${ARCHIVE_TAG}\`）：${ARCHIVE_DESC}。"
  echo "> 🗂️ **保留策略**：\`latest\` 常驻 + 最近 **${KEEP_MONTHS}** 个月的月末归档（约 3 年）；10 日 / 20 日快照只在当月有效，**跨月后上月只留下月末那一份**；上游 \`IPQ807X\` 等其它 Release 一律不动。"
  echo ""
  echo "**IPQ807X 定制固件（自动编译发布）**"
  echo "### 📒 固件信息"
  echo "- 基于主线 laipeng668/openwrt-6.x（${SOURCE_BRANCH}）自动同步编译"
  echo "- 默认主题：**argon**（已移除 Aurora 主题及配置插件）"
  echo "- **默认内置**：${def_list:-（无）}"
  echo "- **本分支新添加内置**：${ADDED_NAMES}"
  echo "- 🌐 默认地址：**192.168.2.1**"
  echo "- 🔑 默认密码：none"
  echo "### 🧊 固件版本"
  echo "- 内核版本：**${VERSION_KERNEL}**"
  echo "- 编译时间：${NOW}"
  echo "- 目标机型：redmi_ax6-stock（squashfs: factory.ubi / sysupgrade.bin）"
  echo "### 🧩 内置插件（编译时拉取的上游版本）"
  echo "**🆕 本分支新添加内置**"
  echo ""
  printf '%s\n' "$ADDED_TABLE"
  echo ""
  echo "**📦 默认内置（随镜像自带）**"
  echo ""
  echo "| 插件 | 版本 | 上游最近更新 | 仓库 |"
  echo "|---|---|---|---|"
  printf '%b' "$def_table"
} > "$BODY"
log "发布说明已生成: $BODY"

############################ 2) 发布/更新 Release ############################

publish() {
  local tag="$1" title="$2"
  if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    gh release edit "$tag" --repo "$REPO" --title "$title" --notes-file "$BODY"
    gh release upload "$tag" "$ART_DIR"/* --repo "$REPO" --clobber
    log "已更新 Release: $tag"
  else
    gh release create "$tag" "$ART_DIR"/* --repo "$REPO" --title "$title" --notes-file "$BODY"
    log "已创建 Release: $tag"
  fi
}

publish "$LATEST_TAG" "${PREFIX} latest"
publish "$ARCHIVE_TAG" "$ARCHIVE_TITLE"

############################ 3) 清理旧 Release ############################
#
# 说明：GitHub 对 Release 数量、Release 总体积、下载带宽都没有上限（单个 Release ≤1000 个资产、
# 单个文件 <2 GiB），所以 3 年 = 36 份归档完全放得下，不必降到 2 年。真正需要控制的是
# Actions artifact 存储（Free 账号 0.5 GB）与编译分钟数，那部分由"每月 3 次 + artifact 保留 3 天"负责。
#
tags="$(gh release list --repo "$REPO" --limit 1000 --json tagName --jq '.[].tagName')"

# 3.1 最近 KEEP_MONTHS 个「月末归档」 -YYYYMM
month_keep="$(printf '%s\n' "$tags" | grep -E "^${PREFIX}-[0-9]{6}$" | sort -r | head -n "$KEEP_MONTHS" || true)"

# 3.2 本月的日快照 -YYYYMMDD（跨月后自然落在保留集合之外，被自动删除）
day_keep="$(printf '%s\n' "$tags" | grep -E "^${PREFIX}-${BUILD_YM}[0-9]{2}$" || true)"

keep="$(printf '%s\n%s\n%s\n' "$month_keep" "$day_keep" "$LATEST_TAG" | sed '/^$/d')"

# 3.3 可选：若 KEEP_SNAPSHOTS=20，额外保留同样 36 个月里每月 20 日的快照
if [ "$KEEP_SNAPSHOTS" = "20" ]; then
  for ym in $(printf '%s\n' "$month_keep" | sed -E "s/^${PREFIX}-([0-9]{6})$/\1/"); do
    t20="${PREFIX}-${ym}20"
    if printf '%s\n' "$tags" | grep -qx -- "$t20"; then
      keep="${keep}"$'\n'"$t20"
    fi
  done
fi

keep="$(printf '%s\n' "$keep" | sed '/^$/d' | sort -u)"
log "保留集合: $(printf '%s' "$keep" | tr '\n' ' ')"

printf '%s\n' "$tags" | while read -r t; do
  [ -n "$t" ] || continue
  case "$t" in
    "${PREFIX}"|"${PREFIX}"-*) ;;
    *) continue ;;   # 非本前缀（例如上游 IPQ807X）一律不动
  esac
  if printf '%s\n' "$keep" | grep -qx -- "$t"; then continue; fi
  log "删除旧 Release: $t"
  gh release delete "$t" --repo "$REPO" --yes --cleanup-tag || true
done

log "完成"
