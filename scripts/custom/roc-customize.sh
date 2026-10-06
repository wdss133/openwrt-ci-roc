#!/usr/bin/env bash
#
# roc-customize.sh —— IPQ807X 定制补丁脚本（幂等 / 耐上游变化）
#
# 运行位置：OpenWrt 源码树根目录（例如 /mnt/openwrt）
# 调用方式：$GITHUB_WORKSPACE/scripts/custom/roc-customize.sh [custom目录]
#
# 设计原则（为了"上游怎么变都能一直用"）：
#   1. 绝不修改 fork 仓库里的主线文件，所有改动只发生在源码树和 CI 工作区副本上；
#   2. 所有写操作幂等，可重复执行；所有删除操作先判断存在性，缺失不报错；
#   3. 外部仓库一律"探测分支 + 失败重试"，上游把默认分支从 master 改成 main 也不会打断；
#   4. 软件包清单集中在 custom/packages.seed，增删包不用改脚本；
#   5. 关键项（argon 主题、kmod-tun）缺失才报错，其余缺失只告警，避免上游小改动直接把流水线打断。
#
set -Eeuo pipefail

CUSTOM_DIR="${1:-${CUSTOM_DIR:-${GITHUB_WORKSPACE:-$PWD}/custom}}"
WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GENERAL_CONFIG="${GENERAL_CONFIG:-$WORKSPACE/configs/General.config}"
DEVICE_CONFIG="${DEVICE_CONFIG:-$WORKSPACE/configs/IPQ807X.config}"
THIRD_PARTY_SOURCES_FILE="${THIRD_PARTY_SOURCES_FILE:-$PWD/third-party-sources.txt}"
# CI 里传进来的可能是相对路径（configs/xxx.config），而脚本运行在源码树，
# 这里统一解析成真实存在的文件，避免"文件不存在"被误判成配置为空。
resolve_existing() {
  local candidate="$1"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
  elif [ -f "$WORKSPACE/$candidate" ]; then
    printf '%s\n' "$WORKSPACE/$candidate"
  else
    printf '%s\n' "$candidate"
  fi
}
DEVICE_CONFIG="$(resolve_existing "$DEVICE_CONFIG")"
GENERAL_CONFIG="$(resolve_existing "$GENERAL_CONFIG")"

DEFAULT_THEME="${DEFAULT_THEME:-argon}"
EASYTIER_VARIANT="${EASYTIER_VARIANT:-noweb}"   # noweb = 预编译二进制（快）；full = 源码编译（慢）
SOURCE_TMP="${SOURCE_TMP:-$PWD/.custom-src}"

log()  { printf '[custom] %s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }

mkdir -p "$SOURCE_TMP"
[ -s "$THIRD_PARTY_SOURCES_FILE" ] || printf 'Repository\tBranch\tCommit\n' > "$THIRD_PARTY_SOURCES_FILE"

############################ 通用工具 ############################

# 探测外部仓库实际存在的分支（按候选顺序），上游改分支名也不会失败
detect_branch() {
  local repo_url="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if git ls-remote --exit-code --heads "$repo_url" "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

record_revision() {
  local repo_url="$1" branch="$2" dir="$3" commit revision
  commit="$(git -C "$dir" rev-parse HEAD)"
  printf -v revision '%s\t%s\t%s' "$repo_url" "$branch" "$commit"
  grep -Fqx -- "$revision" "$THIRD_PARTY_SOURCES_FILE" 2>/dev/null \
    || printf '%s\n' "$revision" >> "$THIRD_PARTY_SOURCES_FILE"
}

# fetch_repo <url> <临时目录> <候选分支...>
fetch_repo() {
  local url="$1" dest="$2"
  shift 2
  local branch attempt
  branch="$(detect_branch "$url" "$@")" || { warn "分支探测失败（$*）: $url"; return 1; }
  rm -rf "$dest"
  for ((attempt = 1; attempt <= 3; attempt++)); do
    if git clone --depth=1 --no-tags --single-branch --branch "$branch" "$url" "$dest" >/dev/null 2>&1; then
      record_revision "$url" "$branch" "$dest"
      log "已获取 $url [$branch]"
      return 0
    fi
    warn "克隆失败，重试 ${attempt}/3: $url"
    sleep $((attempt * 5))
  done
  warn "克隆最终失败: $url"
  return 1
}

# config_set <config文件> <符号> <y|n|m>
config_set() {
  local file="$1" symbol="$2" value="$3"
  [ -f "$file" ] || { warn "配置文件不存在，跳过: $file"; return 0; }
  if grep -Eq "^${symbol}=|^#[[:space:]]+${symbol}[[:space:]]+is[[:space:]]+not[[:space:]]+set" "$file"; then
    sed -i -E "s|^(${symbol})=.*|\1=${value}|; s|^#[[:space:]]+(${symbol})[[:space:]]+is[[:space:]]+not[[:space:]]+set|\1=${value}|" "$file"
  else
    printf '%s=%s\n' "$symbol" "$value" >> "$file"
  fi
}

# 目录存在就删，不存在也不报错
safe_rm() {
  local target
  for target in "$@"; do
    rm -rf "$target" 2>/dev/null || true
  done
}

############################ 1. 定制清单写入主线配置副本 ############################
# 注意：改的是 CI 工作区里 configs/General.config 的副本，不会提交回仓库，
# 因此上游随时改 General.config 都不会产生 git 冲突。

log "应用定制清单: ${CUSTOM_DIR}/packages.seed"
if [ -f "${CUSTOM_DIR}/packages.seed" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    case "$line" in
      '') continue ;;
    esac
    # 注释行：只有 "# CONFIG_xxx is not set" 是有效指令，其余说明文字静默跳过
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      if [[ "$line" =~ ^#[[:space:]]+(CONFIG_[A-Za-z0-9_.-]+)[[:space:]]+is[[:space:]]+not[[:space:]]+set ]]; then
        config_set "$GENERAL_CONFIG" "${BASH_REMATCH[1]}" n
      fi
      continue
    fi
    if [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_.-]+)=(y|n|m|is[[:space:]]+not[[:space:]]+set)$ ]]; then
      config_set "$GENERAL_CONFIG" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_.-]+)=(.*)$ ]]; then
      config_set "$GENERAL_CONFIG" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
      warn "无法解析的定制行，已忽略: $line"
    fi
  done < "${CUSTOM_DIR}/packages.seed"
else
  warn "未找到 ${CUSTOM_DIR}/packages.seed，沿用脚本内置默认值"
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-theme-argon y
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-argon-config y
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-theme-aurora n
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-aurora-config n
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_kmod-tun y
fi

# 这些是硬需求，不管 seed 怎么写都强制生效
config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_kmod-tun y
config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-theme-argon y
config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-theme-aurora n
config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-aurora-config n

############################ 2. 删除 Aurora 主题 ############################

log "移除 Aurora 主题及其配置插件"
safe_rm \
  feeds/luci/themes/luci-theme-aurora \
  feeds/luci/applications/luci-app-aurora-config \
  package/feeds/luci/luci-theme-aurora \
  package/feeds/luci/luci-app-aurora-config \
  package/luci-theme-aurora \
  package/luci-app-aurora-config

# 源码树里任何地方残留的 aurora 目录一并清理（防止 feeds 结构变化后漏网）
while IFS= read -r leftover; do
  safe_rm "$leftover"
done < <(find package feeds -maxdepth 4 -type d \( -name 'luci-theme-aurora' -o -name 'luci-app-aurora-config' \) -print 2>/dev/null || true)

############################ 3. 拉取第三方软件包 ############################

log "拉取第三方软件包"
ez_dir="$SOURCE_TMP/easytier"
zt_dir="$SOURCE_TMP/zerotier"
ddns_dir="$SOURCE_TMP/ddns-go"
istore_dir="$SOURCE_TMP/istore"

# --- EasyTier（含 luci-app-easytier）---
if fetch_repo https://github.com/EasyTier/luci-app-easytier.git "$ez_dir" main master; then
  safe_rm package/easytier
  mkdir -p package/easytier
  cp -a "$ez_dir/." package/easytier/
  # 只保留实际需要的目录，避免同名包被同时选中
  if [ "$EASYTIER_VARIANT" = "noweb" ]; then
    safe_rm package/easytier/easytier
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_easytier-noweb y
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_easytier n
  else
    safe_rm package/easytier/easytier-noweb
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_easytier y
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_easytier-noweb n
  fi
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-easytier y
else
  warn "EasyTier 获取失败，本次编译将不含 EasyTier"
fi

# --- ZeroTier（用 mwarning 维护的新版包替换 feeds 旧版）---
if fetch_repo https://github.com/mwarning/zerotier-openwrt.git "$zt_dir" master main; then
  safe_rm feeds/packages/net/zerotier package/feeds/packages/zerotier package/zerotier
  if [ -d "$zt_dir/zerotier" ]; then
    mv "$zt_dir/zerotier" package/zerotier
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_zerotier y
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-zerotier y
  else
    warn "zerotier 包目录结构变化，未找到 zerotier/ 子目录"
  fi
else
  warn "ZeroTier 获取失败，回退到 feeds 自带版本"
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_zerotier y
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-zerotier y
fi

# --- ddns-go ---
if fetch_repo https://github.com/sirpdboy/luci-app-ddns-go.git "$ddns_dir" main master; then
  safe_rm feeds/packages/net/ddns-go package/feeds/packages/ddns-go package/ddns-go
  safe_rm feeds/luci/applications/luci-app-ddns-go package/feeds/luci/luci-app-ddns-go package/luci-app-ddns-go
  [ -d "$ddns_dir/ddns-go" ] && mv "$ddns_dir/ddns-go" package/ddns-go
  [ -d "$ddns_dir/luci-app-ddns-go" ] && mv "$ddns_dir/luci-app-ddns-go" package/luci-app-ddns-go
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_ddns-go y
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-ddns-go y
else
  warn "ddns-go 获取失败，本次编译将不含 ddns-go"
fi

# --- iStore：4 个子包直接放到 package/ 顶层（与已验证可行的 wechatpush/zerotier 完全相同的落位）---
# OpenWrt 的包扫描为：find -L package -name Makefile | grep 'call (Build/DefaultTargets|BuildPackage|KernelPackage)'
# 只要 Makefile 自身含该串（luci 包末尾的 `# call BuildPackage` 注释即可命中）就会被注册。
# 顶层 package/<pkg>/ 真实目录是本案唯一 100% 验证可行的落位（wechatpush / zerotier 均如此且成功）。
istore_src="$SOURCE_TMP/istore"
if fetch_repo https://github.com/linkease/istore.git "$istore_src" main master; then
  istore_ok=1
  for pkg in luci-app-store luci-lib-taskd luci-lib-xterm taskd; do
    if [ -d "$istore_src/luci/$pkg" ]; then
      safe_rm "package/$pkg"
      cp -a "$istore_src/luci/$pkg" "package/$pkg"
      # 去掉本构建里无法满足的依赖：libuci-lua(24.10+已移除) / tar / mount-utils(未随本 profile 选中)。
      # 这些会生成 `select PACKAGE_xxx`，目标未定义/不可选时会让该包在 defconfig 阶段被静默丢弃。
      find "package/$pkg" -name Makefile -exec sed -i -E 's/[[:space:]]*\+(libuci-lua|tar|mount-utils)//g' {} + 2>/dev/null || true
      log "  已放入 package/$pkg"
    else
      warn "istore 缺少子包 luci/$pkg"; istore_ok=0
    fi
  done
  if [ "$istore_ok" -eq 1 ]; then
    for sym in luci-app-store luci-lib-taskd luci-lib-xterm taskd luci-compat luci-lua-runtime; do
      config_set "$GENERAL_CONFIG" "CONFIG_PACKAGE_$sym" y
    done
    log "  iStore 已按 package/ 顶层落位加入"
  fi
else
  warn "iStore 获取失败，本次编译将不含 iStore"
fi

# --- luci-app-wechatpush（微信 / Telegram / 邮件 推送通知）---
wxp_dir="$SOURCE_TMP/wechatpush"
if fetch_repo https://github.com/tty228/luci-app-wechatpush.git "$wxp_dir" master main; then
  safe_rm package/luci-app-wechatpush
  mkdir -p package/luci-app-wechatpush
  cp -a "$wxp_dir/." package/luci-app-wechatpush/
  rm -rf package/luci-app-wechatpush/.git package/luci-app-wechatpush/.github
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-wechatpush y
  # 依赖（均为 + 软依赖，缺哪个会自动忽略）
  for dep in iputils-arping curl jq bash luci-lua-runtime luci-compat; do
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_$dep y
  done
  log "  已加入 luci-app-wechatpush（微信/Telegram/邮件推送）"
else
  warn "wechatpush 获取失败，本次编译将不含该插件"
fi

############################ 3.5 记录各插件版本与上游更新时间 ############################
# 生成一个 markdown 表，随固件一起打包，并由 Release 写入发布说明。
PLUGIN_INFO_FILE="${PLUGIN_INFO_FILE:-$PWD/${ARTIFACT_PREFIX:-IPQ807X-Custom}.plugins.md}"
{
  printf '| 插件 | 版本 | 上游最近更新 | 仓库 |\n'
  printf '|---|---|---|---|\n'
} > "$PLUGIN_INFO_FILE"
pkg_ver() {
  local f v
  for f in "$@"; do
    [ -f "$f" ] || continue
    v="$(grep -m1 -E '^[[:space:]]*PKG_VERSION[[:space:]]*:?=' "$f" 2>/dev/null | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d ' \r')"
    [ -n "$v" ] || continue
    # 处理 $(or$(X),1.2.3) 这类 make 表达式：取最后一个逗号后的真实版本号
    case "$v" in *'$('*) v="$(printf '%s' "$v" | sed -E 's/.*,([^,()]+)\)[^,()]*$/\1/')" ;; esac
    printf '%s' "$v"; return 0
  done
}
git_date() { git -C "$1" log -1 --format=%cs 2>/dev/null || true; }
plugin_row() {
  local v="${2:-}"; local d="${3:-}"
  printf '| %s | %s | %s | %s |\n' "$1" "${v:-(见固件清单)}" "${d:-(未知)}" "$4" >> "$PLUGIN_INFO_FILE"
}
plugin_row "kmod-tun" "$(pkg_ver "$(find feeds package -path '*kmod-tun/Makefile' -print -quit 2>/dev/null)")" "(随内核 6.12)" "openwrt base"
plugin_row "EasyTier" "$(pkg_ver "package/easytier/luci-app-easytier/Makefile" "package/easytier/easytier-noweb/Makefile")" "$(git_date "$ez_dir")" "https://github.com/EasyTier/luci-app-easytier"
plugin_row "ZeroTier" "$(pkg_ver "package/zerotier/Makefile")" "$(git_date "$zt_dir")" "https://github.com/mwarning/zerotier-openwrt"
plugin_row "ddns-go" "$(pkg_ver "package/ddns-go/Makefile")" "$(git_date "$ddns_dir")" "https://github.com/sirpdboy/luci-app-ddns-go"
plugin_row "iStore (luci-app-store)" "$(pkg_ver "package/luci-app-store/Makefile")" "$(git_date "$istore_src")" "https://github.com/linkease/istore"
plugin_row "wechatpush (luci-app-wechatpush)" "$(pkg_ver "package/luci-app-wechatpush/Makefile")" "$(git_date "$wxp_dir")" "https://github.com/tty228/luci-app-wechatpush"
log "  已生成插件版本信息: $PLUGIN_INFO_FILE"

safe_rm "$SOURCE_TMP"

############################ 4. 默认主题切换为 argon ############################

log "设置默认主题为 ${DEFAULT_THEME}"
theme_switched=0
while IFS= read -r cfg_file; do
  [ -f "$cfg_file" ] || continue
  if grep -q "mediaurlbase" "$cfg_file"; then
    before="$(md5sum "$cfg_file" | awk '{print $1}')"
    sed -i -E "s#(option[[:space:]]+mediaurlbase[[:space:]]+')[^']*(')#\1/luci-static/${DEFAULT_THEME}\2#g" "$cfg_file"
    after="$(md5sum "$cfg_file" | awk '{print $1}')"
    [ "$before" != "$after" ] && { log "  默认主题写入: $cfg_file"; theme_switched=1; }
  fi
done < <(grep -rl "mediaurlbase" feeds package 2>/dev/null || true)

# 兜底：固件首次开机时强制写 uci，即便上面没找到配置文件也能生效
uci_dir="package/base-files/files/etc/uci-defaults"
mkdir -p "$uci_dir"
cat > "${uci_dir}/99_custom_default_theme" <<EOF
#!/bin/sh
# 由 roc-customize.sh 注入：把 LuCI 默认主题固定为 ${DEFAULT_THEME}
[ -x /bin/uci ] || [ -x /sbin/uci ] || exit 0
[ -f /etc/config/luci ] || touch /etc/config/luci
uci -q set luci.main=core
uci -q set luci.main.mediaurlbase='/luci-static/${DEFAULT_THEME}'
uci -q commit luci
exit 0
EOF
chmod +x "${uci_dir}/99_custom_default_theme"
log "  已注入 uci-defaults 兜底脚本"

# 确认 argon 主题源码确实存在，缺失就直接判定失败
if [ ! -d "feeds/luci/themes/luci-theme-argon" ] && [ ! -d "package/luci-theme-argon" ]; then
  die "未找到 luci-theme-argon 源码，无法设置默认主题"
fi
[ "$theme_switched" -eq 1 ] || warn "未在 feeds 中定位到 mediaurlbase 配置文件，已依赖 uci-defaults 兜底"

############################ 4.5 预启用本分支预装的常驻服务 ############################
# 很多第三方包的默认配置是 enabled=0（设计如此）：预装进镜像后，"点启动"不会生效，
# 必须先在 LuCI/uci 里"启用"。这里注入一个首启脚本，把预装服务的默认状态设为"已启用并启动"，
# 做到刷完即用。全部幂等、缺文件不报错。
log "注入首启脚本：预启用预装服务（ddns-go / zerotier）"
uci_dir="package/base-files/files/etc/uci-defaults"
mkdir -p "$uci_dir"
cat > "${uci_dir}/98_custom_enable_services" <<'CUSTOM_EOF'
#!/bin/sh
# 由 roc-customize.sh 注入：预启用本分支预装的常驻服务，避免"预装了但默认不启动"
[ -x /sbin/uci ] || [ -x /bin/uci ] || exit 0

# 兜底创建 ddns-go 用户/组（若预装镜像里未生成）
if [ -x /usr/bin/ddns-go ]; then
	grep -q '^ddns-go:' /etc/passwd 2>/dev/null || echo 'ddns-go:x:32769:32769:ddns-go:/var/run/ddns-go:/bin/false' >> /etc/passwd
	grep -q '^ddns-go:' /etc/group 2>/dev/null || echo 'ddns-go:x:32769:' >> /etc/group
fi

# ddns-go：默认 enabled=0，这里预启用并启动
if [ -f /etc/config/ddns-go ]; then
	uci -q set ddns-go.config.enabled='1'
	uci -q commit ddns-go
fi
[ -x /etc/init.d/ddns-go ] && { /etc/init.d/ddns-go enable; /etc/init.d/ddns-go start; }

# zerotier：预启用；并移除默认的 Earth 测试网络，避免自动加入官方网络
if [ -f /etc/config/zerotier ]; then
	uci -q set zerotier.global.enabled='1'
	uci -q delete zerotier.earth
	while uci -q delete zerotier.@network[0]; do :; done
	uci -q commit zerotier
fi
[ -x /etc/init.d/zerotier ] && { /etc/init.d/zerotier enable; /etc/init.d/zerotier start; }

exit 0
CUSTOM_EOF
chmod +x "${uci_dir}/98_custom_enable_services"
log "  已注入 ${uci_dir}/98_custom_enable_services"

############################ 5. 机型筛选（白名单优先，其次黑名单）############################
# - devices.include：只编译这里列出的机型（其余全部取消），编译时间大幅缩短；
# - devices.exclude：从剩余机型里再剔除（用于出厂分区过小的机型，
#   例如 Zyxel NWA210AX 的 factory 镜像硬限制 60MB，包一多就 "Image file ... is too big"）。
# 两个文件都支持 # 注释；include 有内容时以 include 为准。

include_file="${CUSTOM_DIR}/devices.include"
if [ -f "$include_file" ] && grep -qvE '^[[:space:]]*(#|$)' "$include_file"; then
  keep_list=()
  while IFS= read -r device || [ -n "$device" ]; do
    device="${device%%$'\r'}"
    case "$device" in
      ''|\#*) continue ;;
    esac
    keep_list+=("$device")
  done < "$include_file"

  if [ "${#keep_list[@]}" -gt 0 ] && [ -f "$DEVICE_CONFIG" ]; then
    # 先把所有机型置为未选中（kconfig 的 "# SYMBOL is not set" 写法），再逐个放行
    sed -i -E '/^CONFIG_TARGET_DEVICE_/s/^/# /' "$DEVICE_CONFIG"
    for device in "${keep_list[@]}"; do
      if grep -qE "^# CONFIG_TARGET_DEVICE_[^=]*_DEVICE_${device}=y" "$DEVICE_CONFIG"; then
        sed -i -E "/^# (CONFIG_TARGET_DEVICE_[^=]*_DEVICE_${device})=y/s/^# //" "$DEVICE_CONFIG"
        log "白名单放行机型: $device"
      else
        warn "devices.include 中的 $device 在当前设备配置里不存在，已忽略"
      fi
    done
  fi
fi

exclude_file="${CUSTOM_DIR}/devices.exclude"
if [ -f "$exclude_file" ]; then
  while IFS= read -r device || [ -n "$device" ]; do
    device="${device%%$'\r'}"
    case "$device" in
      ''|\#*) continue ;;
    esac
    if [ -f "$DEVICE_CONFIG" ]; then
      before_count="$(grep -cE "^CONFIG_TARGET_DEVICE_" "$DEVICE_CONFIG" || true)"
      sed -i -E "/^CONFIG_TARGET_DEVICE_[^=]*_DEVICE_${device}=y/d" "$DEVICE_CONFIG"
      after_count="$(grep -cE "^CONFIG_TARGET_DEVICE_" "$DEVICE_CONFIG" || true)"
      # 机型本来就没被选中（白名单已排除或上游改名）时静默跳过，不刷警告
      [ "$before_count" != "$after_count" ] && log "已剔除机型: $device"
    fi
  done < "$exclude_file"
  remaining="$(grep -c "CONFIG_TARGET_DEVICE_" "$DEVICE_CONFIG" 2>/dev/null || echo 0)"
  log "剩余待编译机型数量: $remaining"
  [ "$remaining" -gt 0 ] || die "设备被全部剔除，请检查 ${CUSTOM_DIR}/devices.exclude"
fi

############################ 6. 刷新索引并自检 ############################

# 强制 make defconfig 重新扫描 package/ 树，保证新加入的包能被识别
safe_rm tmp/.packageinfo tmp/.targetinfo tmp/.packageauxvars

log "定制完成："
grep -E "^CONFIG_PACKAGE_(kmod-tun|luci-theme-argon|luci-app-argon-config|luci-theme-aurora|zerotier|luci-app-zerotier|easytier|easytier-noweb|luci-app-easytier|ddns-go|luci-app-ddns-go|luci-app-store)=" "$GENERAL_CONFIG" || true
