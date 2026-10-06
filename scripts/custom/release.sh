#!/usr/bin/env bash
#
# release.sh —— IPQ807X 定制固件「发布」脚本（与 workflow 解耦，便于 fork / 换分支复用）
#
# 职责：
#   1) 依据固件清单与构建阶段产物，生成发布说明：
#        - 固件信息里区分「默认内置」与「本分支新添加内置」
#        - 插件表分两段：先「本分支新添加内置」，再「默认内置」
#   2) 发布/更新两个 Release：
#        - <PREFIX>-latest      滚动最新（下载链接固定）
#        - <PREFIX>-YYYYMM      本月归档（同月内更新为本月最新）
#   3) 清理旧 Release：只保留 latest + 最近 KEEP_MONTHS 个月的月度归档，
#      删除其余以 <PREFIX> 开头的 Release（绝不触碰上游其它 tag，如 IPQ807X）。
#
# 用法：
#   release.sh <artifact_dir> [tag_prefix] [keep_months]
# 环境变量：
#   GH_TOKEN            必填（contents:write），gh CLI 使用
#   GITHUB_REPOSITORY   必填（owner/repo）；本地调试可用 REPO 覆盖
#   VERSION_KERNEL      可选，写入发布说明
#   SOURCE_BRANCH       可选，默认 25.12-nss
#   NEW_LUCI            可选，本分支新增的 luci 应用名（空格分隔），用于从「默认内置」里排除
#
set -Eeuo pipefail

ART_DIR="${1:?用法: release.sh <artifact_dir> [tag_prefix] [keep_months]}"
PREFIX="${2:-IPQ807X-Custom}"
KEEP_MONTHS="${3:-36}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
SOURCE_BRANCH="${SOURCE_BRANCH:-25.12-nss}"
VERSION_KERNEL="${VERSION_KERNEL:-unknown}"
NEW_LUCI="${NEW_LUCI:- luci-app-easytier luci-app-zerotier luci-app-ddns-go luci-app-store luci-app-wechatpush }"

ADDED_NAMES="${ADDED_NAMES:-kmod-tun、EasyTier、ZeroTier、ddns-go、iStore、wechatpush}"

log() { printf '[release] %s\n' "$*"; }
die() { printf '[release][error] %s\n' "$*" >&2; exit 1; }

[ -d "$ART_DIR" ] || die "artifact 目录不存在: $ART_DIR"
[ -n "$REPO" ] || die "需要 GITHUB_REPOSITORY（或 REPO）"
command -v gh >/dev/null 2>&1 || die "未找到 gh CLI"

NOW="$(date -u '+%Y-%m-%d %H:%M UTC')"
LATEST_TAG="${PREFIX}-latest"
MONTH_TAG="${PREFIX}-$(date -u +%Y%m)"
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
  echo "> 📦 **月度归档**（\`${PREFIX}-YYYYMM\`）：同月内每次编译都会覆盖更新，保留的是**该月最后一次成功编译**的产物（每天北京时间 21:00 自动编译 ⇒ 通常就是当月最后一天的成果）。"
  echo "> 🗂️ **保留策略**：\`latest\` 常驻 + 最近 **${KEEP_MONTHS}** 个月度归档（约 3 年），更早的自动清理；上游 \`IPQ807X\` 等其它 Release 一律不动。"
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
publish "$MONTH_TAG" "${MONTH_TAG}（月度归档）"

############################ 3) 清理旧 Release ############################

tags="$(gh release list --repo "$REPO" --limit 300 --json tagName --jq '.[].tagName')"
keep="$(printf '%s\n' "$tags" | grep -E "^${PREFIX}-[0-9]{6}$" | sort -r | head -n "$KEEP_MONTHS" || true)"
keep="${keep}"$'\n'"$LATEST_TAG"
log "保留: $(printf '%s' "$keep" | tr '\n' ' ')"

printf '%s\n' "$tags" | while read -r t; do
  [ -n "$t" ] || continue
  case "$t" in
    "${PREFIX}"|"${PREFIX}"-*) ;;
    *) continue ;;   # 非本前缀（例如上游 IPQ807X）一律不动
  esac
  printf '%s\n' "$keep" | grep -qx -- "$t" && continue
  log "删除旧 Release: $t"
  gh release delete "$t" --repo "$REPO" --yes --cleanup-tag || true
done

log "完成"
