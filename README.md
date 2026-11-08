# IPQ807X 定制固件 CI

> 本仓库是 [laipeng668/openwrt-ci-roc](https://github.com/laipeng668/openwrt-ci-roc) 的**定制分支**：在其基础上自动编译并发布
> **红米 AX6（redmi_ax6_stock）** 专用固件。所有定制均以**新增文件 + 幂等脚本**实现，上游同步不产生冲突，
> 换上游分支 / 重新 fork 后按原要求照跑。

## ✅ 本分支相对上游的实际变更

### 1) 编译机型
只编译下列机型（其余全部关闭，缩短编译时间）：

- redmi_ax6-stock
- 另排除：zyxel_nwa210ax、zyxel_nwa110ax

### 2) 默认主题
- 默认主题改为 **argon**，并移除 Aurora 主题及其配置插件。

### 3) 新增内置插件
（来源于 `custom/packages.seed`）

- luci-theme-argon
- luci-app-argon-config
- kmod-tun
- easytier-noweb
- luci-app-easytier
- zerotier
- luci-app-zerotier
- ddns-go
- luci-app-ddns-go
- luci-app-store

其中第三方插件在编译时从各自上游仓库拉取最新版，并在发布说明中记录**版本号与上游更新日期**。

### 4) 编译节奏与发布策略（全自动）
**每月只编译 3 次**：10 日、20 日、以及**当月最后一天**，均为北京时间 21:00。
月末由工作流里的 `Gate` job 用「明天是不是 1 号」判定，cron 列出 28/29/30/31 兜底，
因此 31 天月、30 天月、平年 2 月 28 日、闰年 2 月 29 日都能正确落在真正的月末，不会多编译也不会漏。

每次编译后：
- 更新滚动 Release `IPQ807X-Custom-latest` —— **下载链接固定**，永远指向最新固件；
- 10 日 / 20 日：生成当月快照 `IPQ807X-Custom-YYYYMM10` / `-YYYYMM20`（**只在当月有效**）；
- 月末：生成月度归档 `IPQ807X-Custom-YYYYMM`（长期保留）；
- **跨月后，上月的 10 日 / 20 日快照自动删除，整月只留下月末那一份**；
- 保留最近 **36** 个月度归档（约 3 年）；上游 `IPQ807X` 等其它 Release 一律不动。

> 为什么降频：GitHub Free 账号的 Actions artifact 存储只有 **0.5 GB**（Support 也无法调高）。
> 原来每天编译 + artifact 保留 3 天，会有 3 份约 200 MB 的产物同时存活 → 约 600 MB 超额，
> 触发 $0 预算阻断（其它仓库会报 "No jobs were run"）。每月 3 次后任一时刻最多 1 份，安全。
> Release 数量 / 总体积 / 下载带宽 GitHub **没有上限**（单个 Release ≤1000 个资产、单文件 <2 GiB），
> 所以 3 年归档不受影响。

### 5) 自动化
- 北京时间 21:00（UTC 13:00）在每月 10 / 20 / 月末自动编译（`.github/workflows/Custom-IPQ807X-Daily.yml`）；
- 非编译日 cron 虽会命中 28~31 号，但 `Gate` 直接跳过，不占用 runner、不产生 artifact；
- 也可在 Actions 页手动 `Run workflow` —— **手动触发不受日历限制**，随时可编译。

## 🚀 刷机
从 `IPQ807X-Custom-latest` 下载对应文件：
- 已刷过 OpenWrt / LibWrt：`sysupgrade -n <...sysupgrade.bin>`（或 LuCI「系统 → 备份/刷写固件」，首刷建议不保留配置）；
- 原厂 / 未刷过：经 uboot / breed 或 initramfs 中转，再用 `...factory.ubi`。

默认地址 **192.168.2.1**，默认密码 **none**。

## 🔁 换分支 / 重新 fork 后继续使用
定制全部收敛在**自有文件**中，迁移时带上这些文件即可按原要求运行：

| 文件 | 作用 |
|---|---|
| `.github/workflows/Custom-IPQ807X-Daily.yml` | 编译 + 发布流水线 |
| `scripts/custom/roc-customize.sh` | 应用全部定制（机型 / 主题 / 插件 / iStore / wechatpush / 插件表） |
| `scripts/custom/release.sh` | 生成发布说明 + `latest`/月度发布 + 清理旧 Release |
| `scripts/custom/gen-readme.sh` | 生成本 README |
| `custom/packages.seed` | 新增/启用插件清单（改包只改这里） |
| `custom/devices.include`、`devices.exclude` | 机型白名单 / 黑名单 |

上游源码：https://github.com/laipeng668/openwrt-6.x（分支 25.12-nss）。

---
_本 README 由 `scripts/custom/gen-readme.sh` 自动生成；要改内容请改脚本或 `custom/` 配置，勿手工大改。_
