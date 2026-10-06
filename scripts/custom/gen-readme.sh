#!/usr/bin/env bash
#
# gen-readme.sh —— 依据仓库“实际配置”重新生成 README（项目根 README.md 与 custom/README.md）
#
# 目的：让 README 永远与本分支的真实变更一致（机型白名单、主题、新增插件、发布策略、迁移说明），
#       不需要人工维护；换上游分支 / 重新 fork 后照旧可用。
#
# 用法：gen-readme.sh [repo_root]
# 环境变量（可选，用于文案）：RELEASE_TAG / KEEP_MONTHS / SOURCE_BRANCH / SOURCE_URL / UPSTREAM_REPO / CUSTOM_DIR
#
set -Eeuo pipefail

ROOT="${1:-${GITHUB_WORKSPACE:-$PWD}}"
cd "$ROOT"

CUSTOM_DIR="${CUSTOM_DIR:-custom}"
SEED="$CUSTOM_DIR/packages.seed"
INC="$CUSTOM_DIR/devices.include"
EXC="$CUSTOM_DIR/devices.exclude"
PREFIX="${RELEASE_TAG:-IPQ807X-Custom}"
KEEP_MONTHS="${KEEP_MONTHS:-36}"
SOURCE_BRANCH="${SOURCE_BRANCH:-25.12-nss}"
SOURCE_URL="${SOURCE_URL:-https://github.com/laipeng668/openwrt-6.x}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/laipeng668/openwrt-ci-roc}"

strip_list() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | tr -d '\r' || true; }

devices_block() {
  if [ -f "$INC" ]; then
    strip_list "$INC" | sed 's/^/- /'
  else
    echo "- (未配置 devices.include)"
  fi
  if [ -f "$EXC" ]; then
    local ex; ex="$(strip_list "$EXC" | paste -sd'、' - || true)"
    [ -n "$ex" ] && echo "- 另排除：$ex"
  fi
}

added_block() {
  if [ -f "$SEED" ]; then
    grep -E '^CONFIG_PACKAGE_[^=]+=y' "$SEED" 2>/dev/null | sed -E 's/^CONFIG_PACKAGE_//; s/=y$//' | sed 's/^/- /' || true
  fi
}

OUT="$(mktemp)"
{
  cat <<EOF
# IPQ807X 定制固件 CI

> 本仓库是 [laipeng668/openwrt-ci-roc](${UPSTREAM_REPO}) 的**定制分支**：在其基础上自动编译并发布
> **红米 AX6（redmi_ax6_stock）** 专用固件。所有定制均以**新增文件 + 幂等脚本**实现，上游同步不产生冲突，
> 换上游分支 / 重新 fork 后按原要求照跑。

## ✅ 本分支相对上游的实际变更

### 1) 编译机型
只编译下列机型（其余全部关闭，缩短编译时间）：

$(devices_block)

### 2) 默认主题
- 默认主题改为 **argon**，并移除 Aurora 主题及其配置插件。

### 3) 新增内置插件
（来源于 \`${CUSTOM_DIR}/packages.seed\`）

$(added_block)

其中第三方插件在编译时从各自上游仓库拉取最新版，并在发布说明中记录**版本号与上游更新日期**。

### 4) 发布策略（全自动）
每次编译后：
- 更新滚动 Release \`${PREFIX}-latest\` —— **下载链接固定**，永远指向最新固件；
- 更新当月归档 Release \`${PREFIX}-YYYYMM\`；
- 自动清理：仅保留 \`latest\` 与最近 **${KEEP_MONTHS}** 个月的月度归档，旧的无上限增长被彻底消除。

### 5) 自动化
- 每日北京时间 21:00 自动编译（\`.github/workflows/Custom-IPQ807X-Daily.yml\`）；
- 也可在 Actions 页手动 \`Run workflow\`（可选是否先同步上游）。

## 🚀 刷机
从 \`${PREFIX}-latest\` 下载对应文件：
- 已刷过 OpenWrt / LibWrt：\`sysupgrade -n <...sysupgrade.bin>\`（或 LuCI「系统 → 备份/刷写固件」，首刷建议不保留配置）；
- 原厂 / 未刷过：经 uboot / breed 或 initramfs 中转，再用 \`...factory.ubi\`。

默认地址 **192.168.2.1**，默认密码 **none**。

## 🔁 换分支 / 重新 fork 后继续使用
定制全部收敛在**自有文件**中，迁移时带上这些文件即可按原要求运行：

| 文件 | 作用 |
|---|---|
| \`.github/workflows/Custom-IPQ807X-Daily.yml\` | 编译 + 发布流水线 |
| \`scripts/custom/roc-customize.sh\` | 应用全部定制（机型 / 主题 / 插件 / iStore / wechatpush / 插件表） |
| \`scripts/custom/release.sh\` | 生成发布说明 + \`latest\`/月度发布 + 清理旧 Release |
| \`scripts/custom/gen-readme.sh\` | 生成本 README |
| \`${CUSTOM_DIR}/packages.seed\` | 新增/启用插件清单（改包只改这里） |
| \`${CUSTOM_DIR}/devices.include\`、\`devices.exclude\` | 机型白名单 / 黑名单 |

上游源码：${SOURCE_URL}（分支 ${SOURCE_BRANCH}）。

---
_本 README 由 \`scripts/custom/gen-readme.sh\` 自动生成；要改内容请改脚本或 \`${CUSTOM_DIR}/\` 配置，勿手工大改。_
EOF
} > "$OUT"

cp "$OUT" README.md
rm -f "$OUT"
printf '[readme] 已生成 README.md\n'
